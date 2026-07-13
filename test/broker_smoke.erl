%%% @doc End-to-end smoke test of the packaged broker running as a real,
%%% standalone node on a real TCP port. Boots tunnel_broker:start/1, brings up
%%% a separate tunnelled node that connects a client to the broker, then issues
%%% public requests to the broker addressed ONLY by Host header and checks that
%%% status, headers and body match a direct request to the tunnelled node.
-module(broker_smoke).
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
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, elmdb]
    ),
    {ok, BrokerAddr} = tunnel_broker:start(<<"standalone/broker.json">>),
    BrokerPort = broker_port(),
    io:format("broker up on ~p as ~s~n", [BrokerPort, BrokerAddr]),

    Store = seed_devices(),
    TargetURL =
        hb_http_server:start_node(#{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"loaded-device-store">> => Store,
            <<"tunnel-protocol">> => http1
        }),
    TargetPort = url_port(TargetURL),
    ok = wait_ready(TargetPort, 10_000),
    {200, _, Address} = raw_get(TargetPort, <<"/~meta@1.0/info/address">>, []),
    io:format("tunnelled node ~s on ~p~n", [Address, TargetPort]),
    Host =
        <<(base32:encode(hb_util:native_id(Address), [lower, nopad]))/binary,
            ".tunnel.example.com">>,

    Direct = [{P, raw_get(TargetPort, P, [])} || P <- ?PATHS],

    ConnectBody =
        hb_json:encode(#{
            <<"peer">> => list_to_binary("http://127.0.0.1:" ++ integer_to_list(BrokerPort)),
            <<"workers">> => 3
        }),
    {202, _, _} =
        raw_post(TargetPort, <<"/~tunnel@1.0/connect">>,
            [{<<"content-type">>, <<"application/json">>}], ConnectBody),
    ok = wait_registered(BrokerPort, Address, 15_000),
    io:format("client registered with broker~n"),

    Tunnelled =
        [
            begin
                wait_registered(BrokerPort, Address, 15_000),
                R = raw_get(BrokerPort, P, [{<<"host">>, Host}]),
                {P, R}
            end
         || P <- ?PATHS
        ],

    io:format("~n== broker parity (public traffic routed by Host only) ==~n"),
    Rows =
        [
            begin
                V = verdict(D, T),
                io:format("~-34s ~s~n", [P, V]),
                {P, V}
            end
         || {{P, D}, {_, T}} <- lists:zip(Direct, Tunnelled)
        ],
    Fail = [P || {P, V} <- Rows, V =/= <<"MATCH">>],
    case Fail of
        [] -> io:format("~nALL MATCH~n");
        _ -> io:format("~nMISMATCH: ~p~n", [Fail])
    end,
    ok.

verdict({S, HD, B}, {S, HD2, B}) ->
    L1 = proplists:get_value(<<"location">>, HD, none),
    L2 = proplists:get_value(<<"location">>, HD2, none),
    C1 = proplists:get_value(<<"content-type">>, HD, none),
    C2 = proplists:get_value(<<"content-type">>, HD2, none),
    case {L1 =:= L2, C1 =:= C2} of
        {true, true} -> <<"MATCH">>;
        _ -> iolist_to_binary(io_lib:format("DIFF(loc ~p/~p ct ~p/~p)", [L1, L2, C1, C2]))
    end;
verdict({S1, _, B1}, {S2, _, B2}) ->
    iolist_to_binary(
        io_lib:format("DIFF(status ~p/~p body ~p/~p)",
            [S1, S2, byte_size(B1), byte_size(B2)]));
verdict(_, Err) ->
    iolist_to_binary(io_lib:format("ERR ~p", [Err])).

broker_port() ->
    {ok, Bin} = file:read_file(<<"standalone/broker.json">>),
    hb_util:int(maps:get(<<"port">>, hb_json:decode(Bin), 8080)).

seed_devices() ->
    Store =
        [#{ <<"store-module">> => hb_store_volatile,
            <<"name">> => <<"smoke-devices">> }],
    hb_store:start(Store),
    _ = code:ensure_loaded(dev_tunnel),
    hb_store:write(Store,
        #{ <<"~meta@1.0/devices/tunnel@1.0">> => <<"dev_tunnel">> }, #{}),
    Store.

wait_ready(Port, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_ready_loop(Port, Deadline).

wait_ready_loop(Port, Deadline) ->
    case catch raw_get(Port, <<"/~meta@1.0/info/address">>, []) of
        {200, _, B} when byte_size(B) > 0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, not_ready};
                false -> timer:sleep(150), wait_ready_loop(Port, Deadline)
            end
    end.

wait_registered(BrokerPort, Address, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(BrokerPort, Address, Deadline).

wait_loop(BrokerPort, Address, Deadline) ->
    Body =
        case raw_get(BrokerPort, <<"/~tunnel@1.0/status">>,
                [{<<"accept">>, <<"application/json">>}]) of
            {200, _, B} -> B;
            _ -> <<>>
        end,
    case binary:match(Body, <<"open-registrations">>) =/= nomatch
        andalso binary:match(Body, <<"\"open-registrations\":0">>) =:= nomatch of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, not_registered};
                false -> timer:sleep(200), wait_loop(BrokerPort, Address, Deadline)
            end
    end.

%%% raw HTTP/1.1 client (Connection: close)
raw_get(Port, Path, Extra) -> raw(<<"GET">>, Port, Path, Extra, <<>>).
raw_post(Port, Path, Extra, Body) -> raw(<<"POST">>, Port, Path, Extra, Body).

raw(Method, Port, Path, Extra, Body) ->
    HostHdr =
        case proplists:get_value(<<"host">>, Extra) of
            undefined -> <<"127.0.0.1">>;
            H -> H
        end,
    Accept =
        case proplists:get_value(<<"accept">>, Extra) of
            undefined -> <<"*/*">>;
            A -> A
        end,
    Base = [{<<"host">>, HostHdr}, {<<"connection">>, <<"close">>},
            {<<"accept">>, Accept}],
    Extra2 = proplists:delete(<<"accept">>, proplists:delete(<<"host">>, Extra)),
    Hdrs = Base ++ Extra2 ++
        case Body of <<>> -> []; _ -> [{<<"content-length">>,
            integer_to_binary(byte_size(Body))}] end,
    Req = [Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
        [[K, <<": ">>, V, <<"\r\n">>] || {K, V} <- Hdrs], <<"\r\n">>, Body],
    {ok, S} = gen_tcp:connect({127,0,0,1}, Port,
        [binary, {packet, raw}, {active, false}], 5000),
    ok = gen_tcp:send(S, Req),
    Raw = recv(S, <<>>),
    gen_tcp:close(S),
    parse(Raw).

recv(S, Acc) ->
    case gen_tcp:recv(S, 0, 120_000) of
        {ok, D} -> recv(S, <<Acc/binary, D/binary>>);
        {error, _} -> Acc
    end.

parse(Raw) ->
    [Head, Body] =
        case binary:split(Raw, <<"\r\n\r\n">>) of
            [H, B] -> [H, B]; [H] -> [H, <<>>] end,
    [SL | HL] = binary:split(Head, <<"\r\n">>, [global]),
    [_, SB | _] = binary:split(SL, <<" ">>, [global]),
    Hdrs = [begin [K, V] = binary:split(L, <<": ">>),
        {hb_util:to_lower(K), V} end
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
        _ -> Acc
    end.

url_port(URL) ->
    U = case binary:last(URL) of $/ -> binary:part(URL,0,byte_size(URL)-1); _ -> URL end,
    #{ port := P } = uri_string:parse(U), P.
