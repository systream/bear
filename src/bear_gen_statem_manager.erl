%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_manager).

-behaviour(gen_server).

%% API
-export([start_link/0, start_handler/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_handler(Id, Module, Args) ->
  Node = on_node(Id),
  rpc:call(Node, bear_gen_statem_sup, start_child, [Id, Module, Args]).

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: #state{}} | {ok, State :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  net_kernel:monitor_nodes(true),
  {ok, #state{}}.

%% @private
%% @doc Handling call messages
-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #state{}) ->
  {reply, Reply :: term(), NewState :: #state{}} |
  {reply, Reply :: term(), NewState :: #state{}, timeout() | hibernate} |
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #state{}} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_call(_Request, _From, State = #state{}) ->
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({nodeup, Node}, State = #state{}) ->
  % wait a but to have all the data replicated to the new nodes
  wait_until_app_started(Node, bear),
  timer:sleep(3000),
  trigger_reallocate(),
  {noreply, State};
handle_info({nodedown, _Node}, State = #state{}) ->
  % in case of down we do not know that it is a network split or a normal down, so do nothing
  {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #state{}) -> term()).
terminate(_Reason, _State = #state{}) ->
  ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #state{},
    Extra :: term()) ->
  {ok, NewState :: #state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

on_node(Id) ->
  Nodes = lists:sort(nodes([visible, this])),
  NodeLength = length(Nodes),
  lists:nth(erlang:phash2(Id, NodeLength) + 1, Nodes).

trigger_reallocate() ->
  lists:foreach(fun({Id, Pid, [Module]}) ->
                  case on_node(Id) of
                    Node when node() =:= Node ->
                      ok;
                    NewNode ->
                      io:format(user, "~p should be reallocated to ~p~n", [Id, NewNode]),
                      {ok, NewPid} = rpc:call(NewNode, bear_gen_statem_sup, start_handoff, [Id, Module]),
                      io:format(user, "~p new server started ~p~n", [Id, NewPid]),
                      ok = bear_gen_statem_handler:handoff(Pid, NewPid),
                      io:format(user, "~p handoff ready ~p~n", [Id, NewPid]),
                      timer:sleep(25)
                  end
                end, bear_gen_statem_sup:children()).

wait_until_app_started(OnNode, App) ->
  case rpc:call(OnNode, application_controller, is_running, [App]) of
    false ->
      timer:sleep(100),
      wait_until_app_started(OnNode, App);
    _ ->
      ok
  end.