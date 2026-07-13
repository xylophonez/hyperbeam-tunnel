%%% @doc Driver half of the standalone-broker smoke test. Assumes a real
%%% tunnel_broker process is already listening on BrokerPort (argv 1). Brings
%%% up a tunnelled node, connects it to that broker, and checks Host-only
%%% public routing parity against direct requests.
-module(broker_driver).
-export([main/1]).

-define(PATHS, [
    <<"/~meta@1.0/info/address">>,
    <<"/">>,
    <<"/~hyperbuddy@1.0/index">>,
    <<"/~hyperbuddy@1.0/bundle.js">>
]).

main([BrokerPortStr]) ->
    BrokerPort = list_to_integer(BrokerPortStr),
    lists:foreach(
        fun(App) -> {ok, _} = application:ensure_all_started(App) end,
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, certifi, hackney, elmdb, prometheus]
    ),
    ok = wait_ready(BrokerPort, 20_000, broker_status),
    io:format("broker reachable on ~p~n", [BrokerPort]),

    Store = seed_devices(),
    TargetURL =
        hb_http_server:start_node(#{
            <<"priv-wallet">> => ar_wallet:new(),
            <<"loaded-device-store">> => Store,
            <<"tunnel-protocol">> => http1
        }),
    TargetPort = url_port(TargetURL),
    ok = wait_ready(TargetPort, 10_000, node),
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
    io:format("client registered with broker~n~n"),

    Tunnelled =
        [
            begin
                wait_registered(BrokerPort, 15_000),
                {P, raw_get(BrokerPort, P, [{<<"host">>, Host}])}
            end
         || P <- ?PATHS
        ],

    io:format("== broker parity (public traffic routed by Host only) ==~n"),
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
        [] -> io:format("~nALL MATCH~n");
        F -> io:format("~nMISMATCH: ~p~n", [F])
    end,
    io:format("~n-- worker survival: 6 rapid scalar checks --~n"),
    R = [element(1, raw_get(BrokerPort, <<"/~meta@1.0/info/address">>,
            [{<<"host">>, Host}])) || _ <- lists:seq(1, 6)],
    io:format("statuses: ~p~n", [R]),
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

seed_devices() ->
    Store = [#{ <<"store-module">> => hb_store_volatile,
        <<"name">> => <<"driver-devices">> }],
    hb_store:start(Store),
    _ = code:ensure_loaded(dev_tunnel),
    hb_store:write(Store,
        #{ <<"~meta@1.0/devices/tunnel@1.0">> => <<"dev_tunnel">> }, #{}),
    Store.

wait_ready(Port, TimeoutMs, Kind) ->
    D = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_ready(Port, D, Kind, path_for(Kind)).

path_for(broker_status) -> <<"/~tunnel@1.0/status">>;
path_for(node) -> <<"/~meta@1.0/info/address">>.

wait_ready(Port, Deadline, Kind, Path) ->
    Acc = case Kind of broker_status -> [{<<"accept">>, <<"application/json">>}]; _ -> [] end,
    case catch raw_get(Port, Path, Acc) of
        {200, _, B} when byte_size(B) > 0 -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true -> {error, not_ready};
                false -> timer:sleep(200), wait_ready(Port, Deadline, Kind, Path)
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
        _ -> Acc
    end.

url_port(URL) ->
    U = case binary:last(URL) of $/ -> binary:part(URL,0,byte_size(URL)-1); _ -> URL end,
    #{ port := P } = uri_string:parse(U), P.
