% License: Apache License, Version 2.0
%
% Copyright 2013 Aircloak
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%     http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.

%% @author Sebastian Probst Eide <sebastian@aircloak.com>
%% @copyright Copyright 2013 Aircloak
%%
%% @doc Riemann client for sending events and states to a riemann server
%%
%% @end
-module(riemann).

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% API
-export([
  start/0,
  stop/0,
  start_link/0,
  send_tcp/1,
  send_udp/1,
  event/1,
  state/1,
  reconfigure/0,
  run_query/1
]).

%% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

%% For private use
-export([
  set_event_val/3,
  set_state_val/3
]).

-include("riemann_pb.hrl").

-record(client, {
    host = undefined,
    port = undefined,
    socket = undefined,
    last_connected_at = -1}).

-record(state, {
    tcp_client = undefined,
    udp_client = undefined
}).

-define(UDP_MAX_SIZE, 16384).
-define(MIN_RECONNECT_INTERVAL, 30). % 30 seconds

-opaque riemann_event() :: #riemannevent{}.
-opaque riemann_state() :: #riemannstate{}.
-type send_response() :: ok | {error, _Reason}.

-type r_query() :: string().

-type r_time() :: {time, non_neg_integer()}.
-type r_state() :: {state, string()}.
-type r_service_name() :: string().
-type r_service() :: {service, r_service_name()}.
-type r_host() :: {host, string()}.
-type r_description() :: {description, string()}.
-type r_tags() :: {tags, [string()]}.
-type r_ttl() :: {ttl, float()}.

-type event_metric() :: {metric, number()}.
-type event_attributes() :: {attributes, [{string(), string()}]}.
-type event_opts() :: 
    event_metric()
  | event_attributes()
  | r_state() 
  | r_service() 
  | r_host() 
  | r_description() 
  | r_tags() 
  | r_ttl() 
  | r_time().

-type state_once() :: {once, boolean()}.
-type state_opts() ::
    state_once()
  | r_state() 
  | r_service() 
  | r_host() 
  | r_description() 
  | r_tags() 
  | r_ttl() 
  | r_time().

%%%===================================================================
%%% API
%%%===================================================================

start() ->
  application:start(?MODULE).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Creates a riemann event. It does not send it to the riemann server.
-spec event([event_opts()]) -> riemann_event().
event(Vals) ->
  create_event(Vals).

%% @doc Creates a riemann state. It does not send it to the riemann server.
-spec state([state_opts()]) -> riemann_state().
state(Vals) ->
  create_state(Vals).

-spec send_tcp([riemann_event() | riemann_state()]) -> send_response().
send_tcp(Entities) when is_list(Entities) ->
  gen_server:call(?MODULE, {send_with_tcp, Entities}).

-spec send_udp([riemann_event() | riemann_state()]) -> send_response().
send_udp(Entities) when is_list(Entities) ->
  gen_server:call(?MODULE, {send_with_udp, Entities}).

-spec run_query(r_query()) -> send_response().
run_query(Query) ->
  gen_server:call(?MODULE, {run_query, Query}).

stop() ->
  gen_server:cast(?MODULE, stop).

reconfigure() ->
  gen_server:call(?MODULE, reconfigure).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

unixtime() ->
  {Mega, Secs, _} = now(),
  Mega * 1000000 + Secs.

init(_) ->
  State = setup_riemann_connectivity(),
  {ok, State}.

handle_call({send_with_tcp, Entities}, _From, S0) ->
  {Reply, S1} = case send_with_tcp(Entities, S0) of
    {{ok, _}, SN} -> {ok, SN};
    Other -> Other
  end,
  {reply, Reply, S1};

handle_call({send_with_udp, Entities}, _From, S0) ->
  {Reply, S1} = case send_with_udp(Entities, S0) of
    {{ok, _}, SN} -> {ok, SN};
    Other -> Other
  end,
  {reply, Reply, S1};

handle_call({run_query, Query}, _From, S0) ->
  {Reply, S1} = case run_query0(Query, S0) of
    {{ok, #riemannmsg{events=Events}}, SN} -> {{ok, Events}, SN};
    Other -> Other
  end,
  {reply, Reply, S1};

handle_call(reconfigure, _From, State) ->
  terminate(reconfigure, State),
  State = setup_riemann_connectivity(),
  {reply, ok, State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(stop, S) ->
  {stop, normal, S};

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #state{udp_client=UdpClient, tcp_client=TcpClient}) ->
  case UdpClient of
    #client{socket = UdpSocket} when UdpSocket =/= undefined ->
      gen_udp:close(UdpSocket);
    _ -> ok
  end,
  case TcpClient of
    #client{socket = TcpSocket} when TcpSocket =/= undefined ->
      gen_tcp:close(TcpSocket);
    _ -> ok
  end,
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

setup_riemann_connectivity() ->
  UdpClient = setup_client(udp),
  TcpClient = setup_client(tcp),
  #state{tcp_client = TcpClient, udp_client = UdpClient}.

setup_client(Protocol) ->
  Clients = get_env(clients, []),
  case proplists:lookup(Protocol, Clients) of
    {Protocol, Host, Port} ->
      setup_client(Protocol, Host, Port);
    none ->
      undefined
  end.

setup_client(Protocol, Host, Port) ->
  case setup_socket(Protocol, Host, Port) of
    {ok, Socket} ->
      #client{host = Host, port = Port, socket = Socket, last_connected_at = unixtime()};
    {error, Reason} ->
      lager:error("Failed opening a ~p socket to riemann with reason ~p", [Protocol, Reason]),
      #client{host = Host, port = Port, last_connected_at = unixtime()}
  end.

setup_socket(udp, _Host, _Port) ->
  gen_udp:open(0, [binary, {active, false}]);

setup_socket(tcp, Host, Port) ->
  Options = [binary, {active,false}, {keepalive, true}, {nodelay, true}],
  Timeout = 10000,
  gen_tcp:connect(Host, Port, Options, Timeout).

reconnect_client(Protocol, #client{last_connected_at = LastConnectedAt} = Client) ->
  reconnect_client(Protocol, Client, ?MIN_RECONNECT_INTERVAL < unixtime() - LastConnectedAt).

reconnect_client(Protocol, #client{}, false) ->
  {error, cooldown};

reconnect_client(Protocol, #client{host = Host, port = Port}, true) ->
  {ok, setup_client(Protocol, Host, Port)}.



get_env(Name, Default) ->
  case application:get_env(riemann, Name) of
    {ok, V} -> V;
    _ -> Default
  end.

run_query0(Query, State) ->
  Msg = #riemannmsg{
      pb_query = #riemannquery{
        string = Query
      }
  },
  BinMsg = iolist_to_binary(riemann_pb:encode_riemannmsg(Msg)),
  send_with_tcp(BinMsg, State).

encode_entities(Entities) ->
  {Events, States} = lists:splitwith(fun(E) -> is_record(E, riemannevent) end, Entities),
  Msg = #riemannmsg{
      events = Events,
      states = States
  },
  iolist_to_binary(riemann_pb:encode_riemannmsg(Msg)).

send_with_tcp(_, #state{tcp_client=undefined} = State) ->
  lager:warning("Failed sending entities to riemann because tcp client is undefined"),
  {{error, tcp_client_undefined}, State};

send_with_tcp(Entities, #state{tcp_client = #client{socket = undefined} = Client} = State) ->
  case reconnect_client(tcp, Client) of
    {ok, #client{socket = Socket} = NewClient} when Socket =/= undefined ->
      NewState = State#state{tcp_client = NewClient},
      send_with_tcp(Entities, NewState);
    {error, Reason} ->
      {{error, Reason}, State}
  end;

send_with_tcp(Entities, #state{tcp_client = #client{socket = TcpSocket} = Client} = State) ->
  BinMsg = encode_entities(Entities),
  MessageSize = byte_size(BinMsg),
  MsgWithLength = <<MessageSize:32/integer-big, BinMsg/binary>>,
  case gen_tcp:send(TcpSocket, MsgWithLength) of
    ok ->
      {await_reply(TcpSocket), State};
    {error, closed} ->
      lager:info("Connection to riemann is closed. Reestablishing connection."),
      case reconnect_client(tcp, Client, true) of
        {ok, NewTcpClient} ->
          send_with_tcp(Entities, State#state{tcp_client = NewTcpClient});
        {error, Reason} ->
          lager:error("Re-establishing a tcp connection to riemann failed because of ~p", [Reason]),
          {{error, Reason}, State}
      end;
    {error, Reason} ->
      lager:error("Failed sending event to riemann with reason: ~p", [Reason]),
      {{error, Reason}, State}
  end.

await_reply(TcpSocket) ->
  case gen_tcp:recv(TcpSocket, 0, 3000) of
    {ok, BinResp} ->
      case decode_response(BinResp) of
        #riemannmsg{ok=true} = Msg -> {ok, Msg};
        #riemannmsg{ok=false, error=Reason} -> {error, Reason}
      end;
    Other -> Other
  end.

send_with_udp(_, #state{udp_client=undefined} = State) ->
  lager:warning("Failed sending entities to riemann because udp client is undefined"),
  {{error, udp_client_undefined}, State};

send_with_udp(Entities, #state{udp_client = #client{socket = undefined} = Client} = State) ->
  case reconnect_client(udp, Client) of
    {ok, NewClient} ->
      NewState = State#state{udp_client = NewClient},
      send_with_udp(Entities, NewState);
    {error, Reason} ->
      {{error, Reason}, State}
  end;

send_with_udp(Entities, #state{udp_client=#client{host = Host, port = Port, socket = UdpSocket}} = State) ->
  ErrorResponses = lists:foldl(fun(Entity, ErrorResponses) ->
      case gen_udp:send(UdpSocket, Host, Port, encode_entities([Entity])) of
        {error, Reason} -> [{Entity, Reason} | ErrorResponses];
        _ -> ErrorResponses
      end
    end, [], Entities),
  case ErrorResponses of
    [] -> {ok, State};
    _ -> {{error, ErrorResponses}, State}
  end.

decode_response(<<MsgLength:32/integer-big, Data/binary>>) ->
  case Data of
    <<Msg:MsgLength/binary, _/binary>> ->
      riemann_pb:decode_riemannmsg(Msg);
    _ ->
      lager:error("Failed at decoding response from riemann"),
      #riemannmsg{
        ok = false,
        error = "Decoding response from Riemann failed"
      }
  end.


%% Creating events

create_event(Vals) ->
  Event = create_base(Vals, #riemannevent{}, fun set_event_val/3, [attributes]),
  Event1 = add_metric_value(Vals, Event),
  set_event_host(Event1).

set_event_val(time, V, E) -> E#riemannevent{time=V};
set_event_val(state, V, E) -> E#riemannevent{state=str(V)};
set_event_val(service, V, E) -> E#riemannevent{service=str(V)};
set_event_val(host, V, E) -> E#riemannevent{host=str(V)};
set_event_val(description, V, E) -> E#riemannevent{description=str(V)};
set_event_val(tags, Tags, E) -> E#riemannevent{tags=[str(T) || T <- Tags]};
set_event_val(ttl, V, E) -> E#riemannevent{ttl=V};
set_event_val(attributes, V, E) -> E#riemannevent{attributes=V}.

add_metric_value(Vals, Event) ->
  case proplists:get_value(metric, Vals, 0) of
    V when is_integer(V) ->
      Event#riemannevent{metric_f = V * 1.0, metric_sint64 = V};
    V ->
      Event#riemannevent{metric_f = V, metric_d = V}
  end.

set_event_host(Event) ->
  case Event#riemannevent.host of
    undefined -> Event#riemannevent{host = default_host_name()};
    _ -> Event
  end.

%% Creating states

create_state(Vals) ->
  State = create_base(Vals, #riemannstate{}, fun set_state_val/3, [once]),
  set_state_host(State).

set_state_host(State) ->
  case State#riemannstate.host of
    undefined -> State#riemannstate{host = default_host_name()};
    _ -> State
  end.

set_state_val(time, V, S) -> S#riemannstate{time=V};
set_state_val(state, V, S) -> S#riemannstate{state=str(V)};
set_state_val(service, V, S) -> S#riemannstate{service=str(V)};
set_state_val(host, V, S) -> S#riemannstate{host=str(V)};
set_state_val(description, V, S) -> S#riemannstate{description=str(V)};
set_state_val(tags, Tags, S) -> S#riemannstate{tags=[str(T) || T <- Tags]};
set_state_val(ttl, V, S) -> S#riemannstate{ttl=V};
set_state_val(once, V, S) -> S#riemannstate{once=V}.

%% Shared creation funs

create_base(Vals, I, F, AdditionalFields) ->
  lists:foldl(fun(Key, E) ->
          case proplists:get_value(Key, Vals) of
            undefined -> E;
            Value -> F(Key, Value, E)
          end
      end, I, [time, state, service, host, description, tags, ttl | AdditionalFields]).

default_host_name() ->
  NodeList = atom_to_list(node()),
  [_, Host] = string:tokens(NodeList, "@"),
  Host.

str(V) when is_atom(V) -> atom_to_list(V);
str(V) -> V.

%%%===================================================================
%%% Tests
%%%===================================================================

-ifdef(TEST).

e() ->
  #riemannevent{metric_f = 0.0}.

create_base_test() ->
  CE = fun(Ps) -> create_base(Ps, e(), fun set_event_val/3, [attributes]) end,
  ?assertEqual(1, (CE([{time,1}]))#riemannevent.time),
  ?assertEqual("ok", (CE([{state,"ok"}]))#riemannevent.state),
  ?assertEqual("test", (CE([{service,"test"}]))#riemannevent.service),
  ?assertEqual("host1", (CE([{host,"host1"}]))#riemannevent.host),
  ?assertEqual("desc", (CE([{description,"desc"}]))#riemannevent.description),
  ?assertEqual(["one", "two"], (CE([{tags,["one", "two"]}]))#riemannevent.tags),
  ?assertEqual(1.0, (CE([{ttl,1.0}]))#riemannevent.ttl),
  ?assertEqual([#riemannattribute{key="key"}], 
               (CE([{attributes,[#riemannattribute{key="key"}]}]))#riemannevent.attributes).

set_metric_value_test() ->
  AM = fun(Ps) -> add_metric_value(Ps, #riemannevent{metric_f = 0.0}) end,
  E1 = AM([{metric, 1}]),
  ?assertEqual(1, E1#riemannevent.metric_sint64),
  ?assertEqual(1.0, E1#riemannevent.metric_f),
  E2 = AM([{metric, 1.0}]),
  ?assertEqual(1.0, E2#riemannevent.metric_d),
  ?assertEqual(1.0, E2#riemannevent.metric_f).

default_node_name_test() ->
  ?assertEqual("nohost", default_host_name()).

set_event_host_test() ->
  E = #riemannevent{host = "host"},
  E1 = set_event_host(E),
  ?assertEqual("host", E1#riemannevent.host),
  E2 = set_event_host(#riemannevent{}),
  ?assertEqual(default_host_name(), E2#riemannevent.host).

set_state_host_test() ->
  E = #riemannstate{host = "host"},
  E1 = set_state_host(E),
  ?assertEqual("host", E1#riemannstate.host),
  E2 = set_state_host(#riemannstate{}),
  ?assertEqual(default_host_name(), E2#riemannstate.host).

-record(c, {
    tcp,
    udp,
    close
}).

conn() ->
  application:set_env(riemann, clients, [{udp, "127.0.0.1", 5555}, {tcp, "127.0.0.1", 5555}]),
  {ok, UdpSocket} = gen_udp:open(5555, [binary, {active, false}]),
  {ok, TcpSocket} = gen_tcp:listen(5555, [binary, {active, false}, {reuseaddr, true}, {nodelay, true}, {exit_on_close, true}]),
  #c{
    udp = UdpSocket,
    tcp = TcpSocket,
    close = fun() ->
        ok = gen_udp:close(UdpSocket),
        ok = gen_tcp:close(TcpSocket)
    end
  }.

end_to_end_event_udp_test() ->
  E = event([{service, "test service"}]),
  F = fun(#riemannmsg{events = Events}) -> Events end,
  end_to_end_udp(E, F).

end_to_end_state_udp_test() ->
  E = state([{service, "test service"}]),
  F = fun(#riemannmsg{states = States}) -> States end,
  end_to_end_udp(E, F).

end_to_end_udp(E, F) ->
  C = conn(),
  try
    start_link(),
    ?assertEqual(ok, send_udp([E])),
    {ok, {_, _, BinMsg}} = gen_udp:recv(C#c.udp, 0),
    Entity = F(riemann_pb:decode_riemannmsg(BinMsg)),
    ?assertEqual(1, length(Entity))
  after
    (C#c.close)(),
    stop()
  end.

tcp_data() ->
  Events = [event([{service, "test service"}, {state, "ok"}, {time, 1000020202}]) || _ <- lists:seq(1, 350)],
  States = [state([{service, "test service"}, {state, "ok"}, {time, 1000020202}]) || _ <- lists:seq(1, 350)],
  F = fun(#riemannmsg{
            events=E,
            states=S
            }) ->
      E =:= Events andalso S =:= States;
          (_) -> 
      false
  end,
  {lists:flatten([Events,States]), F}.

end_to_end_disconnected_tcp_test() ->
  application:set_env(riemann, clients, [{udp, "127.0.0.1", 5555}, {tcp, "127.0.0.1", 5555}]),
  {Events, _} = tcp_data(),
  start_link(),
  Response = send_tcp(Events),
  ?assertEqual({error,cooldown}, Response),
  stop().


end_to_end_reconnect_tcp_test() ->
  {Entities, Validator} = tcp_data(),
  C = conn(),
  start_link(),
  (C#c.close)(),
  C1 = conn(),
  try
    send_and_recv_tcp(Entities, Validator, C1)
  after
    (C1#c.close)(),
    stop()
  end.

end_to_end_event_state_tcp_test() ->
  {Entities, Validator} = tcp_data(),
  end_to_end_tcp(Entities, Validator).

end_to_end_tcp(Es, Validate) ->
  C = conn(),
  try
    start_link(),
    send_and_recv_tcp(Es, Validate, C)
  after
    (C#c.close)(),
    stop()
  end.

send_and_recv_tcp(Es, Validate, C) ->
  S = self(),
  spawn(fun() ->
        R = send_tcp(Es),
        S ! {result, R}
    end),
  {ok, Socket} = gen_tcp:accept(C#c.tcp),
  {ok, <<Length:32/integer-big>>} = gen_tcp:recv(Socket, 4),
  {ok, BinMsg} = gen_tcp:recv(Socket, Length),
  ?assert(Validate(riemann_pb:decode_riemannmsg(BinMsg))),
  Reply = iolist_to_binary(riemann_pb:encode_riemannmsg(#riemannmsg{
      ok = true
  })),
  gen_tcp:send(Socket, <<(byte_size(Reply)):32/integer-big, Reply/binary>>),
  gen_tcp:close(Socket),
  receive {result, ok} -> ok end.
-endif.
