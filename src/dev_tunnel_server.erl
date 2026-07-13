%%% @doc In-memory broker for `tunnel@1.0' reverse HTTP streams.
%%%
%%% The broker holds every registration and pending request for every
%%% tunneled address, so it must never die on account of a single bad
%%% request: wire-form conversion runs inside a guard, and a request that
%%% cannot be forwarded errors its own caller while the worker registration
%%% is returned to the waiting pool.
-module(dev_tunnel_server).
-behaviour(gen_server).

-export([start/0, stop/0, reset/0]).
-export([register/2, call/3, call_available/3, response/3, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include_lib("hb/include/hb.hrl").

%% How long after a registration an address is still considered live for
%% queueing purposes: twice the default register timeout, so a healthy
%% worker's re-registration gap can never be mistaken for a dead tunnel.
-define(LIVENESS_GRACE_MS, 90_000).

%% @doc Start the local tunnel broker if it is not already running.
start() ->
    case whereis(?MODULE) of
        undefined ->
            case gen_server:start({local, ?MODULE}, ?MODULE, [], []) of
                {ok, _PID} -> ok;
                {error, {already_started, _PID}} -> ok
            end;
        _PID ->
            ok
    end.

%% @doc Stop the local tunnel broker.
stop() ->
    case whereis(?MODULE) of
        undefined -> ok;
        _PID -> gen_server:call(?MODULE, stop)
    end.

%% @doc Reset all tunnel state. Intended for tests and explicit operator use.
reset() ->
    call(reset, infinity).

%% @doc Register a waiting HTTP stream for a tunneled address.
register(Address, Timeout) ->
    call({register, Address, Timeout}, infinity).

%% @doc Forward a request to a tunneled address and await its response.
call(Address, Request, Timeout) ->
    call({call, Address, Request, Timeout}, infinity).

%% @doc Forward only if a stream is already registered for the address.
call_available(Address, Request, Timeout) ->
    call({call_available, Address, Request, Timeout}, infinity).

%% @doc Deliver a tunneled response to the waiting caller.
response(ID, Response, Timeout) ->
    call({response, ID, Response}, Timeout).

%% @doc Return broker state useful for observability.
status() ->
    call(status, infinity).

call(Msg, Timeout) ->
    ok = start(),
    gen_server:call(?MODULE, Msg, Timeout).

init([]) ->
    {ok, empty_state()}.

handle_call(reset, _From, State) ->
    cancel_all(State),
    {reply, ok, empty_state()};
handle_call(stop, _From, State) ->
    cancel_all(State),
    {stop, normal, ok, State};
handle_call(status, _From, State) ->
    {reply, {ok, status_message(State)}, State};
handle_call({register, Address, Timeout}, From, State) ->
    RegID = new_id(),
    Timer = start_timer(Timeout, {register_timeout, RegID}),
    Reg = #{
        from => From,
        address => Address,
        timer => Timer
    },
    State1 = put_registration(RegID, Reg, touch_address(Address, State)),
    {noreply, dispatch_to_registration(RegID, State1)};
handle_call({call, Address, Request, Timeout}, From, State) ->
    {ID, State1} = put_request(Address, Request, Timeout, From, State),
    {noreply, dispatch_request(ID, State1)};
handle_call({call_available, Address, Request, Timeout}, From, State) ->
    case dequeue(Address, maps:get(waiters, State)) of
        {ok, RegID, Waiters1} ->
            {ID, State1} =
                put_request(
                    Address,
                    Request,
                    Timeout,
                    From,
                    State#{ waiters => Waiters1 }
                ),
            {noreply, dispatch(RegID, ID, State1)};
        empty ->
            % No worker is waiting right now. If one registered recently the
            % tunnel is alive and merely between long-polls (executing work
            % or re-registering), so queue rather than bounce the caller: a
            % direct LAN client would never observe that gap. Addresses with
            % no recent registration still fail fast.
            case address_recently_live(Address, State) of
                true ->
                    {ID, State1} =
                        put_request(Address, Request, Timeout, From, State),
                    {noreply, dispatch_request(ID, State1)};
                false ->
                    {reply, unavailable(Address), State}
            end
    end;
handle_call({response, ID, Response}, _From, State) ->
    Requests = maps:get(requests, State),
    case maps:take(ID, Requests) of
        {Req, Requests1} ->
            cancel_timer(maps:get(timer, Req, undefined)),
            gen_server:reply(maps:get(from, Req), {ok, Response}),
            {reply, {ok, accepted}, State#{ requests => Requests1 }};
        error ->
            {reply,
                {error,
                    #{
                        <<"status">> => 404,
                        <<"body">> => <<"Unknown tunnel request.">>,
                        <<"tunnel-request-id">> => ID
                    }
                },
                State
            }
    end;
handle_call(Request, _From, State) ->
    {reply, {error, {unknown_call, Request}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({register_timeout, RegID}, State) ->
    Registrations = maps:get(registrations, State),
    case maps:take(RegID, Registrations) of
        {Reg, Registrations1} ->
            gen_server:reply(
                maps:get(from, Reg),
                {ok,
                    #{
                        <<"status">> => 204,
                        <<"body">> => <<"No tunnel work available.">>
                    }
                }
            ),
            {noreply,
                remove_waiter(
                    maps:get(address, Reg),
                    RegID,
                    State#{ registrations => Registrations1 }
                )
            };
        error ->
            {noreply, State}
    end;
handle_info({request_timeout, ID}, State) ->
    Requests = maps:get(requests, State),
    case maps:take(ID, Requests) of
        {Req, Requests1} ->
            Address = maps:get(address, Req),
            gen_server:reply(
                maps:get(from, Req),
                {error,
                    #{
                        <<"status">> => 504,
                        <<"reason">> => <<"tunnel-timeout">>,
                        <<"body">> => <<"Timed out waiting for tunneled response.">>,
                        <<"tunnel-target">> => Address,
                        <<"tunnel-request-id">> => ID
                    }
                }
            ),
            {noreply,
                remove_pending(
                    Address,
                    ID,
                    State#{ requests => Requests1 }
                )
            };
        error ->
            {noreply, State}
    end;
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    cancel_all(State),
    ok.

empty_state() ->
    #{
        waiters => #{},
        registrations => #{},
        requests => #{},
        pending => #{},
        last_seen => #{}
    }.

touch_address(Address, State) ->
    LastSeen = maps:get(last_seen, State, #{}),
    State#{
        last_seen =>
            LastSeen#{ Address => erlang:monotonic_time(millisecond) }
    }.

address_recently_live(Address, State) ->
    case maps:get(Address, maps:get(last_seen, State, #{}), not_found) of
        not_found ->
            false;
        Last ->
            erlang:monotonic_time(millisecond) - Last =< ?LIVENESS_GRACE_MS
    end.

put_registration(RegID, Reg, State) ->
    Address = maps:get(address, Reg),
    Registrations = maps:get(registrations, State),
    State#{
        registrations => Registrations#{ RegID => Reg },
        waiters => enqueue(Address, RegID, maps:get(waiters, State))
    }.

put_request(Address, Request, Timeout, From, State) ->
    ID = new_id(),
    Timer = start_timer(Timeout, {request_timeout, ID}),
    Req = #{
        from => From,
        address => Address,
        request => Request,
        timer => Timer
    },
    Requests = maps:get(requests, State),
    {ID, State#{ requests => Requests#{ ID => Req }}}.

dispatch_to_registration(RegID, State) ->
    Reg = maps:get(RegID, maps:get(registrations, State)),
    Address = maps:get(address, Reg),
    case dequeue(Address, maps:get(pending, State)) of
        {ok, ID, Pending1} ->
            State1 =
                remove_waiter(
                    Address,
                    RegID,
                    State#{ pending => Pending1 }
                ),
            dispatch(RegID, ID, State1);
        empty ->
            State
    end.

dispatch_request(ID, State) ->
    Req = maps:get(ID, maps:get(requests, State)),
    Address = maps:get(address, Req),
    case dequeue(Address, maps:get(waiters, State)) of
        {ok, RegID, Waiters1} ->
            State1 = State#{ waiters => Waiters1 },
            dispatch(RegID, ID, State1);
        empty ->
            State#{ pending => enqueue(Address, ID, maps:get(pending, State)) }
    end.

%% @doc Hand a request to a waiting registration. If the request cannot be
%% converted into wire form, the request's caller receives an error and the
%% registration is returned to the waiting pool -- the broker itself and
%% every other stream survive.
dispatch(RegID, ID, State) ->
    Registrations = maps:get(registrations, State),
    Requests = maps:get(requests, State),
    Reg = maps:get(RegID, Registrations),
    Req = maps:get(ID, Requests),
    case safe_request_message(ID, Req) of
        {ok, Message} ->
            cancel_timer(maps:get(timer, Reg, undefined)),
            gen_server:reply(maps:get(from, Reg), {ok, Message}),
            State#{
                registrations => maps:remove(RegID, Registrations)
            };
        {error, Reason} ->
            ?event(warning, {tunnel_request_unforwardable, ID, Reason}),
            cancel_timer(maps:get(timer, Req, undefined)),
            gen_server:reply(
                maps:get(from, Req),
                {error,
                    #{
                        <<"status">> => 502,
                        <<"reason">> => <<"tunnel-request-unforwardable">>,
                        <<"body">> =>
                            <<"Request could not be forwarded over the tunnel.">>,
                        <<"tunnel-request-id">> => ID
                    }
                }
            ),
            State#{
                requests => maps:remove(ID, Requests),
                waiters =>
                    enqueue(
                        maps:get(address, Reg),
                        RegID,
                        maps:get(waiters, State)
                    )
            }
    end.

%% @doc Build the work message the tunnelled node receives. The forwarded
%% request is INLINED into the top level of the message (its `path', `method'
%% and any scalar headers become top-level keys) rather than nested under a
%% `request' key.
%%
%% Inlining is deliberate and load-bearing for cross-machine use: a nested
%% request sub-message is link-ified by the HTTP codec, and that link does
%% not survive the hop to a different node -- the tunnelled node (or even the
%% broker's own reply encoder) then fails with `necessary_message_not_found'.
%% Inlined scalar keys have no such indirection. A `tunnel-mode' = `envelope'
%% marker tells the (capable) tunnelled node to still reply with the full
%% status/headers/body envelope; brokers that cannot ingest an envelope
%% simply never set it.
safe_request_message(ID, Req) ->
    try
        Wire = wire_request(maps:get(request, Req)),
        Base =
            #{
                <<"status">> => 200,
                <<"tunnel-request-id">> => ID,
                <<"tunnel-target">> => maps:get(address, Req),
                <<"tunnel-mode">> => <<"envelope">>
            },
        {ok, maps:merge(Wire, Base)}
    catch Class:Reason ->
        {error, {Class, Reason}}
    end.

%% @doc Convert a stored request into a flat, codec-safe wire form: a single
%% message map of scalar values with a `path'. Multi-message sequences are
%% collapsed through `hb_singleton:to/1'; anything that cannot be expressed
%% this way raises, which `safe_request_message/2' turns into a caller error.
wire_request([Request = #{ <<"path">> := _ }]) ->
    scrub_request(Request);
wire_request(Request = #{ <<"path">> := _ }) ->
    scrub_request(Request);
wire_request(Request) when is_list(Request) ->
    case hb_singleton:to(Request) of
        Converted = #{ <<"path">> := _ } -> scrub_request(Converted);
        _ -> erlang:error(unforwardable_tunnel_request)
    end;
wire_request(_Request) ->
    erlang:error(unforwardable_tunnel_request).

%% @doc Keep only flat scalar keys of a forwarded request. Nested maps
%% (private state, commitments) are broker-side artifacts that do not
%% survive message codecs losslessly and must not reach the tunneled node.
scrub_request(Request) ->
    maps:filter(
        fun
            (<<"priv">>, _Value) -> false;
            (<<"commitments">>, _Value) -> false;
            (_Key, Value) ->
                is_binary(Value) orelse is_integer(Value)
                    orelse is_boolean(Value) orelse is_atom(Value)
        end,
        Request
    ).

unavailable(Address) ->
    {error,
        #{
            <<"status">> => 404,
            <<"reason">> => <<"tunnel-unavailable">>,
            <<"body">> => <<"Requested tunnel proxy is unavailable.">>,
            <<"tunnel-target">> => Address
        }
    }.

status_message(State) ->
    #{
        <<"registered">> => map_queue_sizes(maps:get(waiters, State)),
        <<"pending">> => map_queue_sizes(maps:get(pending, State)),
        <<"open-registrations">> => map_size(maps:get(registrations, State)),
        <<"open-requests">> => map_size(maps:get(requests, State))
    }.

map_queue_sizes(Map) ->
    maps:map(fun(_Key, Queue) -> queue:len(Queue) end, Map).

enqueue(Key, Value, Map) ->
    Queue = maps:get(Key, Map, queue:new()),
    Map#{ Key => queue:in(Value, Queue) }.

dequeue(Key, Map) ->
    case queue:out(maps:get(Key, Map, queue:new())) of
        {{value, Value}, Queue} ->
            {ok, Value, update_queue(Key, Queue, Map)};
        {empty, _Queue} ->
            empty
    end.

remove_waiter(Address, RegID, State) ->
    State#{ waiters => remove_from_queue(Address, RegID, maps:get(waiters, State)) }.

remove_pending(Address, ID, State) ->
    State#{ pending => remove_from_queue(Address, ID, maps:get(pending, State)) }.

remove_from_queue(Key, Value, Map) ->
    Queue = maps:get(Key, Map, queue:new()),
    Filtered =
        queue:from_list(
            [Item || Item <- queue:to_list(Queue), Item =/= Value]
        ),
    update_queue(Key, Filtered, Map).

update_queue(Key, Queue, Map) ->
    case queue:is_empty(Queue) of
        true -> maps:remove(Key, Map);
        false -> Map#{ Key => Queue }
    end.

start_timer(infinity, _Msg) ->
    undefined;
start_timer(Timeout, Msg) ->
    erlang:send_after(Timeout, self(), Msg).

cancel_timer(undefined) ->
    ok;
cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    ok.

cancel_all(State) ->
    lists:foreach(
        fun(Req) -> cancel_timer(maps:get(timer, Req, undefined)) end,
        maps:values(maps:get(requests, State))
    ),
    lists:foreach(
        fun(Reg) -> cancel_timer(maps:get(timer, Reg, undefined)) end,
        maps:values(maps:get(registrations, State))
    ).

new_id() ->
    hb_util:human_id(crypto:strong_rand_bytes(32)).
