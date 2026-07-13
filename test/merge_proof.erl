%%% @doc Proof that a STOCK HyperBEAM node brokers with ONLY device + config.
%%%
%%% No custom launcher (no tunnel_broker.erl), no loaded-device-store seed. The
%%% broker is `hb_http_server:start_node/1' -- the stock node starter -- given
%%% exactly two things:
%%%   1. `tunnel@1.0' resolvable from the node's device package (the forge
%%%      preloaded store shipped with the runtime), and
%%%   2. config: `on/request => tunnel@1.0/request'.
%%% Then a second node registers, public traffic is routed by Host header only,
%%% and the response is checked byte-for-byte against a direct request. If this
%%% passes, a base LapEE + the tunnel custom device + a broker config is a
%%% working tunnel provider with no other code.
-module(merge_proof).
-export([run/0]).

-define(PATHS, [
    <<"/~meta@1.0/info/address">>,
    <<"/">>,
    <<"/~hyperbuddy@1.0/index">>,
    <<"/~hyperbuddy@1.0/bundle.js">>
]).

run() ->
    lists:foreach(
        fun(App) -> {ok, _} = application:ensure_all_started(App) end,
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, certifi, hackney,
            elmdb]
    ),
    %% STOCK node starter. The only special key is the request hook -- pure
    %% config. tunnel@1.0 is resolved from the preloaded store (HB_PRELOADED_*
    %% env), exactly as a device shipped in a LapEE device package would be.
    %% No seed, no tunnel_broker.
    BrokerURL =
        hb_http_server:start_node(#{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"on">> =>
                #{
                    <<"request">> =>
                        [
                            #{ <<"device">> => <<"manifest@1.0">> },
                            #{ <<"device">> => <<"tunnel@1.0">>, <<"path">> => <<"request">> }
                        ]
                },
            <<"http-extra-opts">> =>
                #{ <<"cache-control">> => [<<"no-store">>, <<"no-cache">>] }
        }),
    BrokerPort = url_port(BrokerURL),
    io:format("stock broker up on ~p (device from preloaded store, config hook only)~n",
        [BrokerPort]),

    %% A tunnelled node -- also stock start_node, tunnel@1.0 from the same
    %% device package for its client connect.
    TargetURL =
        hb_http_server:start_node(#{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"tunnel-protocol">> => http1
        }),
    TargetPort = url_port(TargetURL),
    ok = wait_ready(TargetPort, 10_000),
    {200, _, Address} = raw_get(TargetPort, <<"/~meta@1.0/info/address">>, []),
    Host =
        <<(base32:encode(hb_util:native_id(Address), [lower, nopad]))/binary,
            ".tunnel.example.com">>,
    io:format("tunnelled node ~s -> host ~s~n", [Address, Host]),

    Direct = [{P, raw_get(TargetPort, P, [])} || P <- ?PATHS],

    {202, _, _} =
        raw_post(TargetPort, <<"/~tunnel@1.0/connect">>,
            [{<<"content-type">>, <<"application/json">>}],
            hb_json:encode(#{
                <<"peer">> =>
                    list_to_binary("http://127.0.0.1:" ++ integer_to_list(BrokerPort)),
                <<"workers">> => 3
            })),
    ok = wait_registered(BrokerPort, 15_000),
    io:format("node registered with stock broker~n~n"),

    Tunnelled =
        [
            begin
                wait_registered(BrokerPort, 15_000),
                {P, raw_get(BrokerPort, P, [{<<"host">>, Host}])}
            end
         || P <- ?PATHS
        ],

    io:format("== stock broker parity (Host-routed public vs direct) ==~n"),
    Rows =
        [
            begin
                V = verdict(D, T),
                io:format("~-34s ~s~n", [P, V]),
                V
            end
         || {{P, D}, {_, T}} <- lists:zip(Direct, Tunnelled)
        ],
    case [X || X <- Rows, X =/= <<"MATCH">>] of
        [] -> io:format("~nALL MATCH -- base node + tunnel device + config = broker~n");
        F -> io:format("~nMISMATCH: ~p~n", [F])
    end,
    halt(0).

verdict({S, HD, B}, {S, HD2, B}) ->
    L = fun(H) -> proplists:get_value(<<"location">>, H, none) end,
    C = fun(H) -> proplists:get_value(<<"content-type">>, H, none) end,
    case {L(HD) =:= L(HD2), C(HD) =:= C(HD2)} of
        {true, true} -> <<"MATCH">>;
        _ -> iolist_to_binary(io_lib:format("DIFF(loc ~p/~p ct ~p/~p)",
                [L(HD), L(HD2), C(HD), C(HD2)]))
    end;
verdict({S1, _, B1}, {S2, _, B2}) ->
    iolist_to_binary(io_lib:format("DIFF(status ~p/~p body ~p/~p)",
        [S1, S2, byte_size(B1), byte_size(B2)]));
verdict(_, E) ->
    iolist_to_binary(io_lib:format("ERR ~p", [E])).

wait_ready(Port, TimeoutMs) ->
    D = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_ready(Port, D, loop).
wait_ready(Port, Deadline, loop) ->
    case catch raw_get(Port, <<"/~meta@1.0/info/address">>, []) of
        {200, _, B} when byte_size(B) > 0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, not_ready};
                false -> timer:sleep(200), wait_ready(Port, Deadline, loop)
            end
    end.

wait_registered(BrokerPort, TimeoutMs) ->
    D = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_reg(BrokerPort, D).
wait_reg(BrokerPort, Deadline) ->
    B = case raw_get(BrokerPort, <<"/~tunnel@1.0/status">>,
            [{<<"accept">>, <<"application/json">>}]) of
        {200, _, Body} -> Body; _ -> <<>> end,
    case binary:match(B, <<"open-registrations">>) =/= nomatch
        andalso binary:match(B, <<"\"open-registrations\":0">>) =:= nomatch of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, not_registered};
                false -> timer:sleep(200), wait_reg(BrokerPort, Deadline)
            end
    end.

raw_get(Port, Path, Extra) -> raw(<<"GET">>, Port, Path, Extra, <<>>).
raw_post(Port, Path, Extra, Body) -> raw(<<"POST">>, Port, Path, Extra, Body).
raw(Method, Port, Path, Extra, Body) ->
    HostHdr = case proplists:get_value(<<"host">>, Extra) of
        undefined -> <<"127.0.0.1">>; H -> H end,
    Accept = case proplists:get_value(<<"accept">>, Extra) of
        undefined -> <<"*/*">>; A -> A end,
    Base = [{<<"host">>, HostHdr}, {<<"connection">>, <<"close">>}, {<<"accept">>, Accept}],
    Extra2 = proplists:delete(<<"accept">>, proplists:delete(<<"host">>, Extra)),
    Hdrs = Base ++ Extra2 ++ case Body of <<>> -> [];
        _ -> [{<<"content-length">>, integer_to_binary(byte_size(Body))}] end,
    Req = [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Hdrs], <<"\r\n">>, Body],
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port, [binary, {packet, raw}, {active, false}], 5000),
    ok = gen_tcp:send(S, Req), Raw = recv(S, <<>>), gen_tcp:close(S), parse(Raw).
recv(S, Acc) ->
    case gen_tcp:recv(S, 0, 120_000) of
        {ok, D} -> recv(S, <<Acc/binary, D/binary>>);
        {error, _} -> Acc end.
parse(<<>>) -> {0, [], <<>>};
parse(Raw) ->
    [Head, Body] = case binary:split(Raw, <<"\r\n\r\n">>) of
        [H, B] -> [H, B]; [H] -> [H, <<>>] end,
    [SL | HL] = binary:split(Head, <<"\r\n">>, [global]),
    [_, SB | _] = binary:split(SL, <<" ">>, [global]),
    Hdrs = [begin [K, V] = binary:split(L, <<": ">>), {hb_util:to_lower(K), V} end
        || L <- HL, binary:match(L, <<": ">>) =/= nomatch],
    B2 = case proplists:get_value(<<"transfer-encoding">>, Hdrs) of
        <<"chunked">> -> dechunk(Body, <<>>); _ -> Body end,
    {binary_to_integer(SB), Hdrs, B2}.
dechunk(<<>>, Acc) -> Acc;
dechunk(Bin, Acc) ->
    case binary:split(Bin, <<"\r\n">>) of
        [Sz, Rest] ->
            N = binary_to_integer(hd(binary:split(Sz, <<";">>)), 16),
            case N of 0 -> Acc;
                _ -> <<C:N/binary, _:2/binary, R/binary>> = Rest,
                    dechunk(R, <<Acc/binary, C/binary>>) end;
        _ -> Acc end.
url_port(URL) ->
    U = case binary:last(URL) of $/ -> binary:part(URL,0,byte_size(URL)-1); _ -> URL end,
    #{ port := P } = uri_string:parse(U), P.
