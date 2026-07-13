%%% @doc Reverse HTTP tunnel for reaching nodes behind one-way networks.
%%%
%%% A tunneled node registers an address with a tunnel node using
%%% `/~tunnel@1.0/register'. That request is intentionally long-running: it is
%%% held until work is available, then returns the request that the tunneled
%%% node should execute locally. The tunneled node posts the result back to
%%% `/~tunnel@1.0/response', unblocking the original caller.
%%%
%%% The `request' key is an `on/request' hook. If an inbound HTTP request host
%%% starts with `node-' and a base32 address, that address is used first.
%%% Otherwise a `tunnel-target', `target-node', or `tunnel-node' key forwards
%%% the request sequence over an active registration for that address.
%%%
%%% Responses are carried in a flat `tunnel response envelope': the tunneled
%%% node executes forwarded work against its own HTTP listener (loopback), so
%%% the captured status line, headers, and body are byte-identical to what a
%%% direct LAN client would receive. The envelope ships them as flat scalar
%%% keys (`status', `body', and a JSON `tunnel-headers' map), which survive
%%% message codecs without nesting or link indirection. Brokers that predate
%%% the envelope still deliver the correct body, `location', and
%%% `content-type', which are duplicated as top-level keys.
-module(dev_tunnel).
-implements(<<"tunnel@1.0">>).

-export([info/1]).
-export([register/3, response/3, call/3, request/3, status/3, connect/3]).

-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_REGISTER_TIMEOUT, 45_000).
-define(DEFAULT_RESPONSE_TIMEOUT, 300_000).
-define(DEFAULT_RESPONSE_ACK_TIMEOUT, 5_000).
-define(DEFAULT_RETRY_TIME, 1_000).
-define(DEFAULT_MAX_RETRY_TIME, 60_000).
-define(DEFAULT_WORKERS, 1).
-define(MAX_WORKERS, 16).
-define(LOOPBACK_TIMEOUT, 120_000).

-define(TUNNEL_KEYS, [
    <<"tunnel-target">>,
    <<"target-node">>,
    <<"tunnel-node">>,
    <<"tunnel-timeout">>,
    <<"tunnel-request-id">>
]).

%% Request keys that must not be forwarded to the tunneled node's loopback
%% listener: transport details, message plumbing, and commitments that only
%% held for the broker-side message form.
-define(LOOPBACK_SKIP_KEYS, [
    <<"method">>, <<"path">>, <<"body">>, <<"host">>, <<"connection">>,
    <<"content-length">>, <<"transfer-encoding">>, <<"priv">>,
    <<"status">>, <<"commitments">>, <<"signature">>, <<"signature-input">>,
    <<"content-digest">>, <<"accept-encoding">>
    | ?TUNNEL_KEYS
]).

%% Response headers that are transport-scoped and must be recomputed by
%% whichever server relays the response, never forwarded verbatim.
-define(HOP_HEADERS, [
    <<"connection">>, <<"content-length">>, <<"transfer-encoding">>,
    <<"keep-alive">>, <<"upgrade">>, <<"date">>, <<"server">>
]).

%% Response headers that carry message-layer semantics (signatures, typing)
%% scoped to the tunneled node's own reply. The relaying broker re-signs and
%% re-types its reply, so these must not be replayed into its encoder.
-define(MESSAGE_HEADERS, [
    <<"signature">>, <<"signature-input">>, <<"content-digest">>,
    <<"commitments">>, <<"ao-types">>
]).

%% @doc Return the public keys exported by this device.
info(_M1) ->
    #{
        exports =>
            [
                <<"register">>,
                <<"response">>,
                <<"call">>,
                <<"request">>,
                <<"status">>,
                <<"connect">>
            ]
    }.

%% @doc Register a long-running stream for a tunneled node address.
register(Base, Req, Opts) ->
    case address(Base, Req, Opts) of
        not_found ->
            {error,
                #{
                    <<"status">> => 400,
                    <<"body">> => <<"No tunnel address specified.">>
                }
            };
        Address ->
            Timeout =
                timeout(
                    tunnel_register_timeout,
                    ?DEFAULT_REGISTER_TIMEOUT,
                    Base,
                    Req,
                    Opts
                ),
            Start = erlang:monotonic_time(second),
            Res =
                dev_tunnel_server:register(
                    Address,
                    Timeout
                ),
            case Res of
                {ok, _} -> consume_tunnel_seconds(Start, Opts);
                _ ->
                    ok
            end,
            Res
    end.

%% @doc Return a response for a previously dispatched tunneled request.
response(Base, Req, Opts) ->
    case request_id(Base, Req, Opts) of
        not_found ->
            {error,
                #{
                    <<"status">> => 400,
                    <<"body">> => <<"No tunnel request ID specified.">>
                }
            };
        ID ->
            case tunnel_response(Base, Req, Opts) of
                not_found ->
                    {error,
                        #{
                            <<"status">> => 400,
                            <<"body">> => <<"No tunnel response specified.">>
                        }
                    };
                Response ->
                    Timeout =
                        timeout(
                            tunnel_response_ack_timeout,
                            ?DEFAULT_RESPONSE_ACK_TIMEOUT,
                            Base,
                            Req,
                            Opts
                        ),
                    case dev_tunnel_server:response(ID, Response, Timeout) of
                        {ok, accepted} ->
                            {ok,
                                #{
                                    <<"status">> => 202,
                                    <<"body">> => <<"Accepted">>,
                                    <<"tunnel-request-id">> => ID
                                }
                            };
                        Error ->
                            Error
                    end
            end
    end.

%% @doc Send a request to a registered tunneled node and await the response.
call(Base, Req, Opts) ->
    case call_target(Base, Req, Opts) of
        not_found ->
            {error,
                #{
                    <<"status">> => 400,
                    <<"body">> => <<"No tunnel target specified.">>
                }
            };
        Address ->
            Timeout =
                timeout(
                    tunnel_response_timeout,
                    ?DEFAULT_RESPONSE_TIMEOUT,
                    Base,
                    Req,
                    Opts
                ),
            dev_tunnel_server:call(
                Address,
                target_request(Base, Req, Opts),
                Timeout
            )
    end.

%% @doc `on/request' hook that forwards explicitly tunneled requests. Both
%% host-derived and explicitly targeted requests forward the raw singleton
%% request message (tunnel keys stripped), so the tunneled node sees the
%% same flat request a direct client would have sent it.
request(Base, HookReq, Opts) ->
    RawReq = hb_maps:get(<<"request">>, HookReq, #{}, Opts),
    Body = hb_maps:get(<<"body">>, HookReq, [], Opts),
    case hook_target(Base, RawReq, Body, Opts) of
        not_found ->
            {ok, HookReq};
        {Mode, Address} ->
            Forwarded =
                [
                    sanitize_forwarded(
                        hb_maps:without(
                            [<<"host">> | ?TUNNEL_KEYS],
                            RawReq,
                            Opts
                        ),
                        Opts
                    )
                ],
            Timeout =
                timeout(
                    tunnel_response_timeout,
                    ?DEFAULT_RESPONSE_TIMEOUT,
                    Base,
                    RawReq,
                    Opts
                ),
            Call =
                case Mode of
                    host ->
                        dev_tunnel_server:call_available(
                            Address,
                            Forwarded,
                            Timeout
                        );
                    explicit ->
                        dev_tunnel_server:call(
                            Address,
                            Forwarded,
                            Timeout
                        )
                end,
            case Call of
                {ok, Response} ->
                    {error, hook_response(Response, Opts)};
                Error ->
                    Error
            end
    end.

%% @doc Return broker status.
status(_Base, _Req, _Opts) ->
    dev_tunnel_server:status().

%% @doc Start background client loops from this node to a tunnel peer. The
%% `workers' key (or `tunnel_workers' node option) sets how many concurrent
%% long-poll registrations to hold; more than one keeps the tunnel available
%% while a request is executing.
connect(Base, Req, Opts) ->
    case tunnel_peer(Base, Req, Opts) of
        not_found ->
            {error,
                #{
                    <<"status">> => 400,
                    <<"body">> => <<"No tunnel peer specified.">>
                }
            };
        Peer ->
            Address =
                case address(Base, Req, Opts) of
                    not_found ->
                        hb_util:human_id(
                            ar_wallet:to_address(
                                hb_opts:get(priv_wallet, hb:wallet(), Opts)
                            )
                        );
                    GivenAddress ->
                        GivenAddress
                end,
            Workers = worker_count(Base, Req, Opts),
            ServerID = node_server_id(Opts),
            LoopOpts = Opts#{ <<"http-server">> => ServerID },
            PIDs =
                [
                    spawn(fun() -> client_loop(Peer, Address, LoopOpts) end)
                 || _ <- lists:seq(1, Workers)
                ],
            {ok,
                #{
                    <<"status">> => 202,
                    <<"body">> => <<"Tunnel client started.">>,
                    <<"pid">> => list_to_binary(pid_to_list(hd(PIDs))),
                    <<"pids">> =>
                        [list_to_binary(pid_to_list(PID)) || PID <- PIDs],
                    <<"workers">> => Workers,
                    <<"address">> => Address,
                    <<"peer">> => Peer
                }
            }
    end.

worker_count(Base, Req, Opts) ->
    Raw =
        hb_maps:get_first(
            [
                {Req, <<"workers">>},
                {Base, <<"workers">>},
                {Req, <<"tunnel-workers">>},
                {Base, <<"tunnel-workers">>}
            ],
            hb_opts:get(tunnel_workers, ?DEFAULT_WORKERS, Opts),
            Opts
        ),
    max(1, min(?MAX_WORKERS, hb_util:int(Raw))).

address(Base, Req, Opts) ->
    case hb_maps:get_first(
        [
            {Req, <<"address">>},
            {Base, <<"address">>},
            {Req, <<"tunnel-address">>},
            {Base, <<"tunnel-address">>}
        ],
        not_found,
        Opts
    ) of
        not_found ->
            case hb_message:signers(Req, Opts) of
                [Signer | _] -> normalize_address(Signer);
                [] -> not_found
            end;
        Address ->
            normalize_address(Address)
    end.

call_target(Base, Req, Opts) ->
    normalize_found_address(
        hb_maps:get_first(
            [
                {Req, <<"tunnel-target">>},
                {Base, <<"tunnel-target">>},
                {Req, <<"target-node">>},
                {Base, <<"target-node">>},
                {Req, <<"tunnel-node">>},
                {Base, <<"tunnel-node">>},
                {Req, <<"node">>},
                {Base, <<"node">>},
                {Req, <<"address">>},
                {Base, <<"address">>}
            ],
            not_found,
            Opts
        )
    ).

hook_target(Base, Req, Body, Opts) ->
    case host_target(Req, Opts) of
        not_found -> explicit_hook_target(Base, Req, Body, Opts);
        Address -> {host, Address}
    end.

explicit_hook_target(Base, Req, Body, Opts) ->
    FirstMsg =
        case request_sequence(Body, Opts) of
            [Msg | _] when is_map(Msg) -> Msg;
            _ -> #{}
        end,
    case normalize_found_address(
        hb_maps:get_first(
            [
                {Req, <<"tunnel-target">>},
                {Base, <<"tunnel-target">>},
                {FirstMsg, <<"tunnel-target">>},
                {Req, <<"target-node">>},
                {Base, <<"target-node">>},
                {FirstMsg, <<"target-node">>},
                {Req, <<"tunnel-node">>},
                {Base, <<"tunnel-node">>},
                {FirstMsg, <<"tunnel-node">>}
            ],
            not_found,
            Opts
        )
    ) of
        not_found -> not_found;
        Address -> {explicit, Address}
    end.

%% @doc Derive the tunnelled address from the request's Host header. The
%% first DNS label encodes the 32-byte session address as 52 base32
%% characters. Two spellings are accepted: a bare `<b32>.<domain>' label
%% (what the node's own public URL uses) and a `node-<b32>.<domain>' label
%% (an explicit, unambiguous prefix). Anything else is not a tunnel host.
host_target(Req, Opts) ->
    case binary:split(hb_maps:get(<<"host">>, Req, <<>>, Opts), <<".">>) of
        [<<"node-", HostB32:52/binary>> | _] ->
            decode_host_address(HostB32);
        [Label | _] when byte_size(Label) =:= 52 ->
            decode_host_address(Label);
        _ ->
            not_found
    end.

decode_host_address(HostB32) ->
    try hb_util:human_id(base32:decode(HostB32))
    catch _:_ -> not_found
    end.

tunnel_peer(Base, Req, Opts) ->
    hb_maps:get_first(
        [
            {Req, <<"peer">>},
            {Base, <<"peer">>},
            {Req, <<"tunnel-peer">>},
            {Base, <<"tunnel-peer">>},
            {Req, <<"node">>},
            {Base, <<"node">>}
        ],
        not_found,
        Opts
    ).

request_id(Base, Req, Opts) ->
    hb_maps:get_first(
        [
            {Req, <<"tunnel-request-id">>},
            {Base, <<"tunnel-request-id">>},
            {Req, <<"request-id">>},
            {Base, <<"request-id">>},
            {Req, <<"id">>},
            {Base, <<"id">>}
        ],
        not_found,
        Opts
    ).

%% @doc Extract the response the tunnelled node posted. If it announced an
%% inlined envelope (`tunnel-response' = `envelope'), reassemble the envelope
%% from the top-level keys -- this is the cross-machine-safe form that avoids
%% link indirection. Otherwise fall back to a `response'/`body' value (a bare
%% binary from a body-only client, or a legacy nested response).
tunnel_response(Base, Req, Opts) ->
    case
        hb_maps:get_first(
            [
                {Req, <<"tunnel-response">>},
                {Base, <<"tunnel-response">>}
            ],
            not_found,
            Opts
        )
    of
        <<"envelope">> ->
            inline_envelope(Req, Opts);
        _ ->
            response_message(Base, Req, Opts)
    end.

%% Rebuild the response envelope from the top-level keys of the POST,
%% dropping tunnel control keys and the request's own message-layer keys.
inline_envelope(Req, Opts) when is_map(Req) ->
    hb_maps:without(
        [
            <<"tunnel-response">>, <<"tunnel-request-id">>, <<"request-id">>,
            <<"id">>, <<"accept-bundle">>, <<"method">>, <<"path">>,
            <<"host">>, <<"connection">>, <<"accept">>, <<"content-length">>,
            <<"priv">>, <<"commitments">>, <<"signature">>,
            <<"signature-input">>, <<"content-digest">>, <<"ao-types">>
        ],
        Req,
        Opts
    );
inline_envelope(_Req, _Opts) ->
    not_found.

response_message(Base, Req, Opts) ->
    hb_maps:get_first(
        [
            {Req, <<"response">>},
            {Base, <<"response">>},
            {Req, <<"body">>},
            {Base, <<"body">>}
        ],
        not_found,
        Opts
    ).

target_request(Base, Req, Opts) ->
    case hb_maps:get_first(
        [
            {Req, <<"request">>},
            {Base, <<"request">>}
        ],
        not_found,
        Opts
    ) of
        not_found -> [strip_tunnel_keys(Req, Opts)];
        Request -> strip_tunnel_keys(request_sequence(Request, Opts), Opts)
    end.

request_sequence(Request, _Opts) when is_list(Request) ->
    Request;
request_sequence(Request, Opts) when is_map(Request) ->
    case hb_util:is_ordered_list(Request, Opts) of
        true -> hb_util:message_to_ordered_list(Request, Opts);
        false -> [Request]
    end;
request_sequence(Request, _Opts) ->
    [#{ <<"body">> => Request }].

strip_tunnel_keys(Messages, Opts) when is_list(Messages) ->
    [strip_tunnel_keys(Message, Opts) || Message <- Messages];
strip_tunnel_keys(Message, Opts) when is_map(Message) ->
    hb_maps:without(?TUNNEL_KEYS, Message, Opts);
strip_tunnel_keys(Other, _Opts) ->
    Other.

%% @doc Remove tunnel routing parameters from a forwarded request's path
%% query string, so the tunneled node sees the path a direct caller would
%% have used.
sanitize_forwarded(Req = #{ <<"path">> := Path }, _Opts) when is_binary(Path) ->
    Req#{ <<"path">> => strip_tunnel_query(Path) };
sanitize_forwarded(Req, _Opts) ->
    Req.

strip_tunnel_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [Path] ->
            Path;
        [Base, Query] ->
            Kept =
                [
                    Param
                 || Param <- binary:split(Query, <<"&">>, [global]),
                    not is_tunnel_param(Param)
                ],
            case Kept of
                [] -> Base;
                _ -> <<Base/binary, "?", (join_params(Kept))/binary>>
            end
    end.

is_tunnel_param(Param) ->
    Key = hd(binary:split(Param, <<"=">>)),
    lists:member(Key, ?TUNNEL_KEYS).

join_params([First | Rest]) ->
    lists:foldl(
        fun(Param, Acc) -> <<Acc/binary, "&", Param/binary>> end,
        First,
        Rest
    ).

%% @doc Build the hook reply from a tunneled response. Envelope responses
%% carry the loopback-captured status, headers, and raw body; legacy
%% responses pass through with a defaulted status.
hook_response(Response, Opts) when is_map(Response) ->
    case hb_maps:get(<<"tunnel-headers">>, Response, not_found, Opts) of
        not_found ->
            legacy_hook_response(Response);
        HeadersJSON ->
            Headers =
                try hb_json:decode(hb_util:bin(HeadersJSON))
                catch _:_ -> #{}
                end,
            Status =
                try hb_util:int(hb_maps:get(<<"status">>, Response, 200, Opts))
                catch _:_ -> 200
                end,
            RespBody = hb_maps:get(<<"body">>, Response, <<>>, Opts),
            maps:merge(
                relayable_headers(Headers),
                #{
                    <<"status">> => Status,
                    <<"body">> => RespBody
                }
            )
    end;
hook_response(Response, _Opts) ->
    legacy_hook_response(Response).

legacy_hook_response(Response = #{ <<"status">> := _ }) ->
    Response;
legacy_hook_response(Response) when is_map(Response) ->
    Response#{ <<"status">> => 200 };
legacy_hook_response(Response) ->
    #{ <<"status">> => 200, <<"body">> => Response }.

relayable_headers(Headers) when is_map(Headers) ->
    maps:filter(
        fun(Key, Value) ->
            LowerKey = hb_util:to_lower(Key),
            is_binary(Value) andalso
                not lists:member(LowerKey, ?HOP_HEADERS) andalso
                not lists:member(LowerKey, ?MESSAGE_HEADERS)
        end,
        Headers
    );
relayable_headers(_) ->
    #{}.

timeout(Key, Default, Base, Req, Opts) ->
    Raw =
        hb_maps:get_first(
            [
                {Req, <<"tunnel-timeout">>},
                {Base, <<"tunnel-timeout">>}
            ],
            hb_opts:get(Key, Default, Opts),
            Opts
        ),
    case Raw of
        infinity -> infinity;
        <<"infinity">> -> infinity;
        _ -> hb_util:int(Raw)
    end.

consume_tunnel_seconds(Start, Opts) ->
    case hb_opts:get(<<"metering-rates">>, #{}, Opts) of
        Rates when is_map(Rates), map_size(Rates) > 0 ->
            {ok, Metering} = hb_device_load:reference(<<"metering@1.0">>, Opts),
            Metering:consume(
                <<"tunnel-seconds">>,
                erlang:monotonic_time(second) - Start,
                Opts
            );
        _ ->
            ok
    end.

normalize_found_address(not_found) ->
    not_found;
normalize_found_address(Address) ->
    normalize_address(Address).

normalize_address(Address) ->
    try hb_util:human_id(Address)
    catch _:_ -> hb_util:bin(Address)
    end.

node_server_id(Opts) ->
    hb_util:human_id(
        ar_wallet:to_address(hb_opts:get(priv_wallet, hb:wallet(), Opts))
    ).

client_loop(Peer, Address, Opts) ->
    client_loop(Peer, Address, Opts, 0).

client_loop(Peer, Address, Opts, FailureCount) ->
    case ensure_http_server_ready(Opts) of
        ok ->
            client_loop_ready(Peer, Address, Opts, FailureCount);
        {error, Reason} ->
            ?event(warning, {tunnel_client_waiting_for_http_server, Reason}),
            retry_sleep(FailureCount, Opts),
            client_loop(Peer, Address, Opts, FailureCount + 1)
    end.

client_loop_ready(Peer, Address, Opts, FailureCount) ->
    RegisterTimeout =
        hb_opts:get(tunnel_register_timeout, ?DEFAULT_REGISTER_TIMEOUT, Opts),
    HTTPOpts = client_http_opts(Opts, RegisterTimeout),
    RegMsg =
        #{
            <<"address">> => Address,
            <<"tunnel-timeout">> => RegisterTimeout,
            <<"accept-bundle">> => true
        },
    case hb_http:post(Peer, <<"/~tunnel@1.0/register">>, RegMsg, HTTPOpts) of
        {ok, #{ <<"status">> := 204 }} ->
            client_loop(Peer, Address, Opts, 0);
        {ok, Work = #{ <<"tunnel-request-id">> := ID }} ->
            handle_work(Peer, ID, Work, HTTPOpts, Opts),
            client_loop(Peer, Address, Opts, 0);
        Error ->
            ?event(warning, {tunnel_client_error, Error}),
            retry_sleep(FailureCount, Opts),
            client_loop(Peer, Address, Opts, FailureCount + 1)
    end.

retry_sleep(FailureCount, Opts) ->
    Base = hb_opts:get(tunnel_retry_time, ?DEFAULT_RETRY_TIME, Opts),
    Max = hb_opts:get(tunnel_max_retry_time, ?DEFAULT_MAX_RETRY_TIME, Opts),
    Exponent = min(FailureCount, 6),
    Delay = min(Max, Base * (1 bsl Exponent)),
    timer:sleep(rand:uniform(max(1, Delay))).

%% @doc Execute one item of tunneled work and post its response. Failures
%% are contained: a crashing execution produces an error envelope and the
%% worker loop always survives to re-register.
%%
%% The response wire form depends on what the broker can actually carry, and
%% the work format tells us which broker we are talking to:
%%
%% <ul>
%%   <li><b>Envelope brokers</b> wrap forwarded work under a `request' key and
%%       understand the flat response envelope, so they receive full status,
%%       headers and body -- real parity with a direct LAN request.</li>
%%   <li><b>Body-only brokers</b> (e.g. smoke.solutions today) inline the
%%       request into the work message, and cannot ingest a structured
%%       response at all: a sub-message reaches them as a content-addressed
%%       link that their node cannot resolve, and the POST fails with
%%       `necessary_message_not_found'. Only a bare binary crosses. We send
%%       one, having first followed any local redirect ourselves, so the
%%       public caller still receives the page it asked for rather than a
%%       redirect it cannot see.</li>
%% </ul>
handle_work(Peer, ID, Work, HTTPOpts, Opts) ->
    Mode = broker_mode(Work, Opts),
    Response =
        try response_for(Mode, Work, Opts)
        catch Class:Reason:Stack ->
            ?event(warning,
                {tunnel_client_work_error, ID, Class, Reason, Stack}),
            error_response(Mode)
        end,
    case
        hb_http:post(
            Peer,
            <<"/~tunnel@1.0/response">>,
            response_post(Mode, ID, Response),
            HTTPOpts
        )
    of
        {ok, _} -> ok;
        Error -> ?event(warning, {tunnel_client_response_error, ID, Error})
    end.

%% @doc Build the `/~tunnel@1.0/response' POST body. In envelope mode the
%% response fields are INLINED at the top level (mirroring the inlined work
%% request): a response nested under a `response' key is link-ified by the
%% codec and the link cannot be resolved by the broker on the other side,
%% failing with `necessary_message_not_found'. A `tunnel-response' = `envelope'
%% marker tells the broker to reassemble the envelope from the top-level keys.
%% In body-only mode the response is a bare binary, which carries fine under a
%% `response' key with no indirection.
response_post(envelope, ID, Response) when is_map(Response) ->
    maps:merge(
        Response,
        #{
            <<"tunnel-request-id">> => ID,
            <<"tunnel-response">> => <<"envelope">>,
            <<"accept-bundle">> => true
        }
    );
response_post(_Mode, ID, Response) ->
    #{
        <<"tunnel-request-id">> => ID,
        <<"response">> => Response,
        <<"accept-bundle">> => true
    }.

%% @doc Decide the response wire form from the work message. A broker that
%% can ingest the full envelope announces it, either with an explicit
%% `tunnel-mode' = `envelope' marker (this broker, which inlines the request)
%% or by wrapping the request under a `request' key (older envelope brokers).
%% Everything else is a body-only broker (e.g. smoke.solutions).
broker_mode(Work, Opts) ->
    case hb_maps:get(<<"tunnel-mode">>, Work, not_found, Opts) of
        <<"envelope">> ->
            envelope;
        _ ->
            case hb_maps:get(<<"request">>, Work, not_found, Opts) of
                not_found -> body_only;
                _ -> envelope
            end
    end.

response_for(envelope, Work, Opts) ->
    execute_work(Work, Opts);
response_for(body_only, Work, Opts) ->
    Envelope = execute_work(Work, Opts),
    hb_maps:get(<<"body">>, follow_redirects(Envelope, Opts), <<>>, Opts).

error_response(envelope) ->
    #{
        <<"status">> => 502,
        <<"body">> => <<"Tunneled execution failed.">>,
        <<"tunnel-headers">> => <<"{}">>
    };
error_response(body_only) ->
    <<"Tunneled execution failed.">>.

%% @doc Resolve redirects locally, because a body-only broker cannot relay the
%% status and `location' a browser would need to follow them itself.
follow_redirects(Envelope, Opts) ->
    follow_redirects(Envelope, Opts, 3).

follow_redirects(Envelope, _Opts, 0) ->
    Envelope;
follow_redirects(Envelope = #{ <<"status">> := Status }, Opts, Remaining)
        when Status >= 300, Status < 400 ->
    case hb_maps:get(<<"location">>, Envelope, not_found, Opts) of
        not_found ->
            Envelope;
        Location ->
            Next =
                execute_work(
                    #{ <<"request">> => #{ <<"path">> => Location } },
                    Opts
                ),
            follow_redirects(Next, Opts, Remaining - 1)
    end;
follow_redirects(Envelope, _Opts, _Remaining) ->
    Envelope.

ensure_http_server_ready(Opts) ->
    case hb_maps:get(<<"http-server">>, Opts, not_found, Opts) of
        not_found ->
            ok;
        ServerID ->
            hb_http_server:set_proc_server_id(ServerID),
            case
                hb_util:wait_until(
                    fun() -> http_server_ready(ServerID) end,
                    30_000
                )
            of
                true -> ok;
                false -> {error, {http_server_not_ready, ServerID}}
            end
    end.

http_server_ready(ServerID) ->
    try is_map(hb_http_server:get_opts(#{ <<"http-server">> => ServerID }))
    catch _:_ -> false
    end.

client_http_opts(Opts, RegisterTimeout) ->
    DefaultHTTPTimeout =
        case RegisterTimeout of
            infinity -> ?DEFAULT_RESPONSE_TIMEOUT;
            <<"infinity">> -> ?DEFAULT_RESPONSE_TIMEOUT;
            _ -> hb_util:int(RegisterTimeout) + ?DEFAULT_RESPONSE_ACK_TIMEOUT
        end,
    Opts#{
        <<"http-client">> => hb_opts:get(tunnel_http_client, gun, Opts),
        <<"protocol">> =>
            hb_opts:get(
                tunnel_protocol,
                hb_opts:get(protocol, http2, Opts),
                Opts
            ),
        <<"http-only-result">> => false,
        <<"http-client-send-timeout">> =>
            hb_opts:get(
                tunnel_http_timeout,
                DefaultHTTPTimeout,
                Opts
            )
    }.

%% @doc Execute forwarded work against this node's own HTTP listener and
%% wrap the raw result in a flat response envelope. Looping the request
%% back through the real listener means redirects, content types, static
%% assets, and error pages are captured exactly as a direct client sees
%% them.
execute_work(Work, Opts) ->
    Request = work_request(Work, Opts),
    Port = loopback_port(Opts),
    {Status, Headers, Body} = loopback_http(Port, Request, Opts),
    envelope(Status, Headers, Body).

%% @doc Extract the request a broker wants us to execute. Two wire formats
%% are in the wild and both must work:
%%
%% <ul>
%%   <li><b>Wrapped</b> (this broker): the request sits under a `request'
%%       key, possibly as a message sequence.</li>
%%   <li><b>Inlined</b> (smoke.solutions): the work message IS the request --
%%       `path' and `method' are top-level keys alongside the tunnel
%%       metadata, with no `request' key at all. Reading `request' here and
%%       finding nothing yields an empty request, which every node resolves
%%       to its default (the root 307) -- so every tunneled path would come
%%       back as "Redirecting to default request." regardless of what was
%%       asked for.</li>
%% </ul>
work_request(Work, Opts) ->
    case hb_maps:get(<<"request">>, Work, not_found, Opts) of
        not_found ->
            inlined_request(Work, Opts);
        Raw ->
            wrapped_request(Raw, Work, Opts)
    end.

wrapped_request(Raw, Work, Opts) ->
    Sequence = request_sequence(Raw, Opts),
    case Sequence of
        [Request = #{ <<"path">> := _ }] ->
            Request;
        _ ->
            case raw_request_safe(Sequence) of
                Request = #{ <<"path">> := _ } ->
                    Request;
                _ ->
                    case first_pathful(Sequence) of
                        #{ <<"path">> := <<"/">> } -> inlined_request(Work, Opts);
                        Request -> Request
                    end
            end
    end.

%% @doc Treat the work message itself as the request, dropping the tunnel
%% metadata and the broker's own message-layer keys.
inlined_request(Work, Opts) ->
    Request =
        hb_maps:without(
            [
                <<"status">>, <<"commitments">>, <<"signature">>,
                <<"signature-input">>, <<"content-digest">>, <<"ao-types">>,
                <<"accept-bundle">>, <<"priv">>, <<"tunnel-mode">>
                | ?TUNNEL_KEYS
            ],
            Work,
            Opts
        ),
    case hb_maps:get(<<"path">>, Request, not_found, Opts) of
        not_found -> #{ <<"path">> => <<"/">> };
        _ -> Request
    end.

raw_request_safe(Sequence) ->
    try hb_singleton:to(Sequence)
    catch _:_ -> not_found
    end.

first_pathful([Msg = #{ <<"path">> := _ } | _]) -> Msg;
first_pathful([_ | Rest]) -> first_pathful(Rest);
first_pathful([]) -> #{ <<"path">> => <<"/">> }.

envelope(Status, Headers, Body) ->
    Kept =
        [
            {hb_util:to_lower(Key), Value}
         || {Key, Value} <- Headers,
            not lists:member(hb_util:to_lower(Key), ?HOP_HEADERS)
        ],
    Base =
        #{
            <<"status">> => Status,
            <<"body">> => Body,
            <<"tunnel-headers">> => hb_json:encode(maps:from_list(Kept))
        },
    % Duplicate navigation-critical headers as top-level keys so legacy
    % brokers, which relay the response message untouched, still forward
    % them to the public caller.
    lists:foldl(
        fun(Key, Acc) ->
            case proplists:get_value(Key, Kept) of
                undefined -> Acc;
                Value -> Acc#{ Key => Value }
            end
        end,
        Base,
        [<<"location">>, <<"content-type">>]
    ).

%% @doc The local listener's actual bound port. Ranch knows the truth even
%% when the node was configured with port 0; the configured port is the
%% fallback when the listener is not registered under the server ID.
loopback_port(Opts) ->
    FromRanch =
        case hb_maps:get(<<"http-server">>, Opts, not_found, Opts) of
            not_found ->
                not_found;
            ServerID ->
                try ranch:get_port(ServerID)
                catch _:_ -> not_found
                end
        end,
    case FromRanch of
        Port when is_integer(Port), Port > 0 ->
            Port;
        _ ->
            hb_util:int(hb_opts:get(port, 8734, Opts))
    end.

%% @doc Perform a forwarded request against the local listener with a raw
%% HTTP/1.1 client. Every non-transport scalar key of the forwarded message
%% is carried as a request header, which is equivalent to the query/header
%% form the direct caller used (AO-Core treats them identically).
loopback_http(Port, Request, Opts) ->
    Method =
        string:uppercase(
            hb_util:bin(hb_maps:get(<<"method">>, Request, <<"GET">>, Opts))
        ),
    Path = hb_maps:get(<<"path">>, Request, <<"/">>, Opts),
    Body = loopback_body(hb_maps:get(<<"body">>, Request, <<>>, Opts)),
    Headers =
        [
            {hb_util:to_lower(hb_util:bin(Key)), hb_util:bin(Value)}
         || {Key, Value} <- hb_maps:to_list(Request, Opts),
            is_scalar(Value),
            not lists:member(
                hb_util:to_lower(hb_util:bin(Key)),
                ?LOOPBACK_SKIP_KEYS
            )
        ],
    HeaderLines =
        [
            [Key, <<": ">>, Value, <<"\r\n">>]
         || {Key, Value} <- Headers
        ],
    LengthLine =
        case {Body, Method} of
            {<<>>, <<"GET">>} -> [];
            _ ->
                [<<"content-length: ">>,
                    integer_to_binary(byte_size(Body)), <<"\r\n">>]
        end,
    Wire =
        [
            Method, <<" ">>, ensure_leading_slash(Path), <<" HTTP/1.1\r\n">>,
            <<"host: 127.0.0.1\r\n">>,
            <<"connection: close\r\n">>,
            HeaderLines,
            LengthLine,
            <<"\r\n">>,
            Body
        ],
    {ok, Sock} =
        gen_tcp:connect(
            {127, 0, 0, 1},
            Port,
            [binary, {packet, raw}, {active, false}],
            ?LOOPBACK_TIMEOUT
        ),
    ok = gen_tcp:send(Sock, Wire),
    Raw = loopback_recv(Sock, <<>>),
    gen_tcp:close(Sock),
    parse_http_response(Raw).

loopback_body(Body) when is_binary(Body) -> Body;
loopback_body(_) -> <<>>.

is_scalar(Value) ->
    is_binary(Value) orelse is_integer(Value) orelse is_boolean(Value)
        orelse is_atom(Value).

ensure_leading_slash(Path = <<"/", _/binary>>) -> Path;
ensure_leading_slash(Path) -> <<"/", Path/binary>>.

loopback_recv(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, ?LOOPBACK_TIMEOUT) of
        {ok, Data} -> loopback_recv(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

parse_http_response(Raw) ->
    [Head, RawBody] =
        case binary:split(Raw, <<"\r\n\r\n">>) of
            [H, B] -> [H, B];
            [H] -> [H, <<>>]
        end,
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Headers =
        [
            begin
                [Key, Value] = binary:split(Line, <<": ">>),
                {Key, Value}
            end
         || Line <- HeaderLines, binary:match(Line, <<": ">>) =/= nomatch
        ],
    Body =
        case proplists:get_value(<<"transfer-encoding">>, Headers) of
            <<"chunked">> -> dechunk(RawBody, <<>>);
            _ -> RawBody
        end,
    {binary_to_integer(StatusBin), Headers, Body}.

dechunk(<<>>, Acc) ->
    Acc;
dechunk(Bin, Acc) ->
    case binary:split(Bin, <<"\r\n">>) of
        [SizeHex, Rest] ->
            Size = binary_to_integer(hd(binary:split(SizeHex, <<";">>)), 16),
            case Size of
                0 -> Acc;
                _ ->
                    <<Chunk:Size/binary, _CRLF:2/binary, Rest1/binary>> = Rest,
                    dechunk(Rest1, <<Acc/binary, Chunk/binary>>)
            end;
        _ ->
            Acc
    end.

-ifdef(TEST).

new_test_address() ->
    hb_util:human_id(crypto:strong_rand_bytes(32)).

new_test_host(Address) ->
    <<"node-", (base32:encode(hb_util:native_id(Address), [lower, nopad]))/binary,
        ".example">>.

roundtrip_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Parent = self(),
        spawn(
            fun() ->
                {ok, Work} =
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    ),
                Parent ! {work, Work},
                ID = maps:get(<<"tunnel-request-id">>, Work),
                {ok, _} =
                    response(
                        #{},
                        #{
                            <<"tunnel-request-id">> => ID,
                            <<"response">> => #{ <<"body">> => <<"pong">> }
                        },
                        #{}
                    )
            end
        ),
        {ok, #{ <<"body">> := <<"pong">> }} =
            call(
                #{},
                #{
                    <<"address">> => Address,
                    <<"request">> => [#{ <<"path">> => <<"ping">> }]
                },
                #{ <<"tunnel-response-timeout">> => 5_000 }
            ),
        receive
            {work, Work} ->
                [#{ <<"path">> := <<"ping">> }] = work_request_sequence(Work),
                ok
        after 1000 ->
            error(no_tunnel_work_observed)
        end
    after
        dev_tunnel_server:stop()
    end.

request_hook_roundtrip_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Parent = self(),
        spawn(
            fun() ->
                {ok, Work} =
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    ),
                Parent ! {hook_work, Work},
                ID = maps:get(<<"tunnel-request-id">>, Work),
                {ok, _} =
                    response(
                        #{},
                        #{
                            <<"tunnel-request-id">> => ID,
                            <<"response">> => #{ <<"answer">> => 42 }
                        },
                        #{}
                    )
            end
        ),
        HookReq =
            #{
                <<"request">> =>
                    #{
                        <<"path">> => <<"/remote/answer">>,
                        <<"tunnel-target">> => Address
                    },
                <<"body">> =>
                    [
                        #{
                            <<"path">> => <<"answer">>,
                            <<"tunnel-target">> => Address
                        }
                    ]
            },
        {error, #{ <<"answer">> := 42, <<"status">> := 200 }} =
            request(#{}, HookReq, #{ <<"tunnel-response-timeout">> => 5_000 }),
        receive
            {hook_work, Work} ->
                [Forwarded] = work_request_sequence(Work),
                ?assertEqual(error, maps:find(<<"tunnel-target">>, Forwarded)),
                ?assertEqual(<<"/remote/answer">>, maps:get(<<"path">>, Forwarded))
        after 1000 ->
            error(no_tunnel_hook_work_observed)
        end
    after
        dev_tunnel_server:stop()
    end.

host_request_roundtrip_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Host = new_test_host(Address),
        Parent = self(),
        spawn(
            fun() ->
                {ok, Work} =
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    ),
                Parent ! {host_work, Work},
                {ok, _} =
                    response(
                        #{},
                        #{
                            <<"tunnel-request-id">> =>
                                maps:get(<<"tunnel-request-id">>, Work),
                            <<"response">> =>
                                #{
                                    <<"status">> => 200,
                                    <<"body">> => <<"from-host">>
                                }
                        },
                        #{}
                    )
            end
        ),
        true =
            hb_util:wait_until(
                fun() ->
                    {ok, Status} = status(#{}, #{}, #{}),
                    maps:get(
                        Address,
                        maps:get(<<"registered">>, Status, #{}),
                        0
                    ) =:= 1
                end,
                1000
            ),
        {error, #{ <<"body">> := <<"from-host">>, <<"status">> := 200 }} =
            request(
                #{},
                #{
                    <<"request">> =>
                        #{
                            <<"host">> => Host,
                            <<"path">> => <<"/~meta@1.0/info/address">>
                        },
                    <<"body">> => [#{ <<"path">> => <<"wrong">> }]
                },
                #{ <<"tunnel-response-timeout">> => 5_000 }
            ),
        receive
            {host_work, Work} ->
                [Forwarded] = work_request_sequence(Work),
                ?assertEqual(
                    <<"/~meta@1.0/info/address">>,
                    maps:get(<<"path">>, Forwarded)
                ),
                ?assertEqual(error, maps:find(<<"host">>, Forwarded))
        after 1000 ->
            error(no_host_hook_work_observed)
        end
    after
        dev_tunnel_server:stop()
    end.

work_request_sequence(Work) ->
    request_sequence(maps:get(<<"request">>, Work), #{}).

host_unavailable_returns_fast_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        OtherAddress = new_test_address(),
        Host = new_test_host(Address),
        <<"node-", B32:52/binary, ".example">> = Host,
        ?assertEqual(
            not_found,
            host_target(#{ <<"host">> => <<"node-", B32/binary, "x.example">> }, #{})
        ),
        {error,
            #{
                <<"status">> := 404,
                <<"reason">> := <<"tunnel-unavailable">>,
                <<"tunnel-target">> := Address
            }} =
            request(
                #{},
                #{
                    <<"request">> =>
                        #{
                            <<"host">> => Host,
                            <<"tunnel-target">> => OtherAddress
                        },
                    <<"body">> =>
                        [
                            #{
                                <<"path">> => <<"answer">>,
                                <<"tunnel-target">> => OtherAddress
                            }
                        ]
                },
                #{ <<"tunnel-response-timeout">> => 5_000 }
            )
    after
        dev_tunnel_server:stop()
    end.

register_timeout_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Opts =
            #{
                <<"tunnel-register-timeout">> => 1_100,
                <<"metering-rates">> => #{ <<"tunnel-seconds">> => 1 }
            },
        {ok, Metering} =
            hb_device_load:reference(<<"metering@1.0">>, Opts),
        {ok, 0} = Metering:estimate(#{}, #{}, Opts),
        {ok, #{ <<"status">> := 204 }} =
            register(
                #{},
                #{ <<"address">> => Address },
                Opts
            ),
        {ok, Price} = Metering:price(#{}, #{}, Opts),
        ?assert(Price >= 1)
    after
        dev_tunnel_server:stop()
    end.

envelope_execute_work_test() ->
    Wallet = ar_wallet:new(),
    ServerID = hb_util:human_id(ar_wallet:to_address(Wallet)),
    hb_http_server:start_node(
        #{
            <<"port">> => 0,
            <<"priv-wallet">> => Wallet
        }
    ),
    NodeMsg = hb_http_server:get_opts(#{ <<"http-server">> => ServerID }),
    Res =
        execute_work(
            #{
                <<"request">> =>
                    #{ <<"path">> => <<"/~meta@1.0/info/address">> }
            },
            NodeMsg
        ),
    ?assertMatch(#{ <<"status">> := 200 }, Res),
    ?assertEqual(ServerID, maps:get(<<"body">>, Res)),
    Headers = hb_json:decode(maps:get(<<"tunnel-headers">>, Res)),
    ?assert(is_map(Headers)).

envelope_execute_work_redirect_test() ->
    Wallet = ar_wallet:new(),
    ServerID = hb_util:human_id(ar_wallet:to_address(Wallet)),
    hb_http_server:start_node(
        #{
            <<"port">> => 0,
            <<"priv-wallet">> => Wallet
        }
    ),
    NodeMsg = hb_http_server:get_opts(#{ <<"http-server">> => ServerID }),
    Res =
        execute_work(
            #{ <<"request">> => #{ <<"path">> => <<"/">> } },
            NodeMsg
        ),
    ?assertMatch(#{ <<"status">> := 307 }, Res),
    ?assertEqual(
        <<"/~hyperbuddy@1.0/index">>,
        maps:get(<<"location">>, Res)
    ).

serializes_pending_requests_test_() ->
    {timeout, 10, fun serializes_pending_requests/0}.

serializes_pending_requests() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Parent = self(),
        spawn(
            fun() ->
                Parent ! {
                    work1,
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    )
                }
            end
        ),
        spawn(
            fun() ->
                Parent ! {
                    caller1,
                    call(
                        #{},
                        #{
                            <<"address">> => Address,
                            <<"tunnel-timeout">> => 5_000,
                            <<"request">> => [#{ <<"path">> => <<"first">> }]
                        },
                        #{}
                    )
                }
            end
        ),
        ID1 =
            receive
                {work1,
                    {ok,
                        #{
                            <<"tunnel-request-id">> := WorkID1,
                            <<"request">> := #{ <<"path">> := <<"first">> }
                        }
                    }} ->
                    WorkID1
            after 1000 ->
                error(no_first_work_observed)
            end,
        spawn(
            fun() ->
                Parent ! {
                    caller2,
                    call(
                        #{},
                        #{
                            <<"address">> => Address,
                            <<"tunnel-timeout">> => 5_000,
                            <<"request">> => [#{ <<"path">> => <<"second">> }]
                        },
                        #{}
                    )
                }
            end
        ),
        timer:sleep(50),
        {ok, Status} = status(#{}, #{}, #{}),
        ?assertEqual(2, maps:get(<<"open-requests">>, Status)),
        ?assertEqual(1, maps:get(Address, maps:get(<<"pending">>, Status))),
        receive
            {caller2, _} ->
                error(second_request_replied_before_registration)
        after 100 ->
            ok
        end,
        {ok, _} =
            response(
                #{},
                #{
                    <<"tunnel-request-id">> => ID1,
                    <<"response">> => #{ <<"body">> => <<"one">> }
                },
                #{}
            ),
        receive
            {caller1, {ok, #{ <<"body">> := <<"one">> }}} ->
                ok
        after 1000 ->
            error(first_caller_not_released)
        end,
        receive
            {caller2, _} ->
                error(second_request_replied_without_registration)
        after 100 ->
            ok
        end,
        spawn(
            fun() ->
                Parent ! {
                    work2,
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    )
                }
            end
        ),
        ID2 =
            receive
                {work2,
                    {ok,
                        #{
                            <<"tunnel-request-id">> := WorkID2,
                            <<"request">> := #{ <<"path">> := <<"second">> }
                        }
                    }} ->
                    WorkID2
            after 1000 ->
                error(no_second_work_observed)
            end,
        {ok, _} =
            response(
                #{},
                #{
                    <<"tunnel-request-id">> => ID2,
                    <<"response">> => #{ <<"body">> => <<"two">> }
                },
                #{}
            ),
        receive
            {caller2, {ok, #{ <<"body">> := <<"two">> }}} ->
                ok
        after 1000 ->
            error(second_caller_not_released)
        end
    after
        dev_tunnel_server:stop()
    end.

poison_request_does_not_kill_broker_test() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Parent = self(),
        % A request whose sequence cannot be converted into wire form must
        % error its own caller only; the broker and later work must survive.
        spawn(
            fun() ->
                Parent ! {
                    poison,
                    call(
                        #{},
                        #{
                            <<"address">> => Address,
                            <<"tunnel-timeout">> => 5_000,
                            <<"request">> =>
                                [{as, <<"meta@1.0">>, #{}}, <<"info">>]
                        },
                        #{}
                    )
                }
            end
        ),
        timer:sleep(50),
        spawn(
            fun() ->
                Parent ! {
                    work,
                    register(
                        #{},
                        #{ <<"address">> => Address },
                        #{ <<"tunnel-register-timeout">> => 5_000 }
                    )
                }
            end
        ),
        receive
            {poison, {error, #{ <<"status">> := 502 }}} -> ok;
            {poison, Other} -> error({unexpected_poison_result, Other})
        after 2000 ->
            error(poison_request_never_replied)
        end,
        % Broker must still answer status and hold the registration.
        {ok, _} = status(#{}, #{}, #{}),
        spawn(
            fun() ->
                Parent ! {
                    caller,
                    call(
                        #{},
                        #{
                            <<"address">> => Address,
                            <<"tunnel-timeout">> => 5_000,
                            <<"request">> => [#{ <<"path">> => <<"alive">> }]
                        },
                        #{}
                    )
                }
            end
        ),
        ID =
            receive
                {work, {ok, #{ <<"tunnel-request-id">> := WorkID }}} ->
                    WorkID
            after 2000 ->
                error(no_work_after_poison)
            end,
        {ok, _} =
            response(
                #{},
                #{
                    <<"tunnel-request-id">> => ID,
                    <<"response">> => #{ <<"body">> => <<"alive">> }
                },
                #{}
            ),
        receive
            {caller, {ok, #{ <<"body">> := <<"alive">> }}} -> ok
        after 2000 ->
            error(caller_not_released_after_poison)
        end
    after
        dev_tunnel_server:stop()
    end.

http_hook_roundtrip_test_() ->
    {timeout, 30, fun http_hook_roundtrip/0}.

http_hook_roundtrip() ->
    try
        dev_tunnel_server:reset(),
        Address = new_test_address(),
        Node =
            hb_http_server:start_node(
                #{
                    <<"priv-wallet">> => ar_wallet:new(),
                    <<"on">> =>
                        #{
                            <<"request">> =>
                                #{
                                    <<"device">> => <<"tunnel@1.0">>,
                                    <<"path">> => <<"request">>
                                }
                        },
                    <<"http-extra-opts">> =>
                        #{
                            <<"cache-control">> =>
                                [<<"no-store">>, <<"no-cache">>]
                        }
                }
            ),
        Parent = self(),
        spawn(
            fun() ->
                RegRes =
                    hb_http:post(
                        Node,
                        <<"/~tunnel@1.0/register">>,
                        #{
                            <<"address">> => Address,
                            <<"accept-bundle">> => true
                        },
                        http_test_opts()
                    ),
                Parent ! {http_register, RegRes},
                case RegRes of
                    {ok, Work = #{ <<"tunnel-request-id">> := ID }} ->
                        Parent ! {http_work, Work},
                        Parent ! {
                            http_response,
                            hb_http:post(
                                Node,
                                <<"/~tunnel@1.0/response">>,
                                #{
                                    <<"tunnel-request-id">> => ID,
                                    <<"response">> =>
                                        #{ <<"body">> => <<"from-tunnel">> },
                                    <<"accept-bundle">> => true
                                },
                                http_test_opts()
                            )
                        };
                    _ ->
                        ok
                end
            end
        ),
        {ok, #{ <<"body">> := <<"from-tunnel">> }} =
            hb_http:get(
                Node,
                <<"/remote/path?tunnel-target=", Address/binary>>,
                http_test_opts()
            ),
        receive
            {http_register, {ok, #{ <<"tunnel-target">> := Address }}} ->
                ok
        after 1000 ->
            error(no_http_register_result)
        end,
        receive
            {http_work, #{ <<"request">> := Forwarded }} ->
                [Msg | _] = request_sequence(Forwarded, #{}),
                ?assertEqual(<<"/remote/path">>, maps:get(<<"path">>, Msg)),
                ok
        after 1000 ->
            error(no_http_work_observed)
        end,
        receive
            {http_response, {ok, #{ <<"status">> := 202 }}} ->
                ok
        after 1000 ->
            error(no_http_response_ack)
        end
    after
        dev_tunnel_server:stop()
    end.

http_test_opts() ->
    #{
        <<"http-client">> => gun,
        <<"protocol">> => http2,
        <<"http-client-send-timeout">> => 10_000,
        <<"http-only-result">> => false,
        <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
    }.

-endif.
