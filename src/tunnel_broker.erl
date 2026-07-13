%%% @doc Standalone entrypoint for a self-hosted `tunnel@1.0' reverse HTTP
%%% tunnel broker.
%%%
%%% A broker is an ordinary HyperBEAM node whose `on/request' hook is the
%%% `tunnel@1.0' device. Tunnelled nodes (behind NAT, roaming, on mobile
%%% data) hold long-poll registrations against it; public traffic that
%%% arrives for `https://<address-base32>.<broker-domain>/...' is matched to
%%% the registration by the first DNS label and executed on the tunnelled
%%% node, and its full HTTP response (status, headers, body) is relayed back.
%%%
%%% This module is deliberately small: it loads a JSON config, loads or
%%% creates a persistent broker wallet, ensures the `tunnel@1.0' device is
%%% resolvable, and starts the node. Run it with `run.sh' (see the repo
%%% README) or embed `start/0,1' in your own release.
-module(tunnel_broker).

-export([start/0, start/1, main/1]).

-define(DEFAULT_CONFIG, <<"standalone/broker.json">>).
-define(DEFAULT_PORT, 8080).
-define(DEFAULT_WALLET, <<"broker-wallet.json">>).

%% @doc escript / `erl -run' entrypoint.
main([]) ->
    start(),
    idle();
main([ConfigPath]) ->
    start(unicode:characters_to_binary(ConfigPath)),
    idle().

idle() ->
    receive
        stop -> ok
    end.

start() ->
    Config =
        case os:getenv("BROKER_CONFIG") of
            false -> ?DEFAULT_CONFIG;
            Path -> unicode:characters_to_binary(Path)
        end,
    start(Config).

start(ConfigPath) ->
    ensure_apps(),
    hb:init(),
    Loaded = load_config(ConfigPath),
    Wallet = load_or_create_wallet(Loaded),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    Store = configured_store(Loaded),
    hb_store:start(Store),
    NodeMsg =
        maps:merge(
            Loaded,
            #{
                <<"priv-wallet">> => Wallet,
                <<"address">> => Address,
                <<"store">> => Store,
                <<"port">> => port(Loaded),
                %% The tunnel device is the request hook: every inbound public
                %% request is offered to it before normal resolution.
                <<"on">> =>
                    #{
                        <<"request">> =>
                            #{
                                <<"device">> => <<"tunnel@1.0">>,
                                <<"path">> => <<"request">>
                            }
                    },
                %% Control-plane and relayed responses must never be cached.
                <<"http-extra-opts">> =>
                    #{ <<"cache-control">> => [<<"no-store">>, <<"no-cache">>] },
                <<"loaded-device-store">> => device_store(Loaded)
            }
        ),
    ok = seed_tunnel_device(NodeMsg),
    %% Same client/metrics bring-up an hb node normally performs at boot.
    %% Without these, outbound HTTP paths and Prometheus counters used while
    %% relaying tunnelled work are uninitialised and requests fail with 500.
    hb_http_client:setup_conn(NodeMsg),
    _ = hb_http_client:init_prometheus(),
    io:format("tunnel-broker: starting on port ~p as ~s~n",
        [port(Loaded), Address]),
    {ok, _Listener} = hb_http_server:start(NodeMsg),
    io:format(
        "tunnel-broker: ready. public host form: <node-address-base32>.<your-domain>~n",
        []
    ),
    {ok, Address}.

%%% ------------------------------------------------------------------

ensure_apps() ->
    lists:foreach(
        fun(App) ->
            case application:ensure_all_started(App) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok;
                {error, Reason} ->
                    erlang:error({failed_to_start_broker_app, App, Reason})
            end
        end,
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, certifi, hackney,
            elmdb, prometheus]
    ).

port(Loaded) ->
    hb_util:int(hb_maps:get(<<"port">>, Loaded, ?DEFAULT_PORT, #{})).

%% @doc A volatile device store pre-seeded so `tunnel@1.0' resolves to the
%% broker's own `dev_tunnel' module. This makes the broker runnable directly
%% against a compiled source tree, with no forge/preloaded-store build. On a
%% node that already preloads `tunnel@1.0' the seed is simply redundant.
device_store(_Loaded) ->
    [
        #{
            <<"store-module">> => hb_store_volatile,
            <<"name">> => <<"tunnel-broker-devices">>
        }
    ].

seed_tunnel_device(NodeMsg) ->
    Store = hb_maps:get(<<"loaded-device-store">>, NodeMsg, [], #{}),
    hb_store:start(Store),
    _ = code:ensure_loaded(dev_tunnel),
    _ = code:ensure_loaded(dev_tunnel_server),
    hb_store:write(
        Store,
        #{ <<"~meta@1.0/devices/tunnel@1.0">> => <<"dev_tunnel">> },
        #{}
    ).

configured_store(Loaded) ->
    case hb_maps:get(<<"store">>, Loaded, not_found, #{}) of
        not_found ->
            [
                #{
                    <<"store-module">> => hb_store_volatile,
                    <<"name">> => <<"tunnel-broker-store">>
                }
            ];
        Store ->
            Store
    end.

load_config(ConfigPath) ->
    case file:read_file(ConfigPath) of
        {ok, Bin} ->
            decode(hb_json:decode(Bin));
        {error, enoent} ->
            io:format("tunnel-broker: no config at ~ts, using defaults~n",
                [ConfigPath]),
            #{};
        {error, Reason} ->
            erlang:error({failed_to_load_broker_config, ConfigPath, Reason})
    end.

decode(Map) when is_map(Map) -> Map;
decode(_) -> #{}.

%% @doc Load a persistent broker wallet from `broker-wallet.json' (or the
%% `wallet' config key), creating and persisting one on first run so the
%% broker keeps a stable identity across restarts. Set `"wallet":
%% "ephemeral"' to use a throwaway key instead.
load_or_create_wallet(Loaded) ->
    case hb_maps:get(<<"wallet">>, Loaded, ?DEFAULT_WALLET, #{}) of
        <<"ephemeral">> ->
            ar_wallet:new();
        Path ->
            load_wallet_file(Path)
    end.

load_wallet_file(Path) ->
    PathStr = unicode:characters_to_list(Path),
    case filelib:is_regular(PathStr) of
        true ->
            ar_wallet:load_keyfile(PathStr);
        false ->
            Wallet = ar_wallet:new(),
            ok = filelib:ensure_dir(PathStr),
            ok = file:write_file(PathStr, ar_wallet:to_json(Wallet)),
            io:format("tunnel-broker: created wallet ~ts~n", [Path]),
            Wallet
    end.
