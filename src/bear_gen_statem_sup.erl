%%%-------------------------------------------------------------------
%%% @author tihi
%%% @copyright (C) 2025, <COMPANY>
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(bear_gen_statem_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/3,
         children/0,
         start_handoff/2,
         terminate_child/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

start_child(Id, Module, Args) ->
  case supervisor:start_child(?SERVER, child_spec(Id, Module, Args)) of
    {error, already_present} ->
      supervisor:delete_child(?SERVER, Id),
      start_child(Id, Module, Args);
    {error, {already_started, Pid}} ->
      {ok, Pid};
    Else ->
      Else
  end.

terminate_child(Id) ->
  case supervisor:terminate_child(?SERVER, Id) of
    ok ->
      supervisor:delete_child(?SERVER, Id);
    Else ->
      Else
  end.

start_handoff(Id, Module) ->
  supervisor:start_child(?SERVER, child_spec(Id, Module)).

children() ->
  [{Id, Pid, Modules} ||
    {Id, Pid, worker, [bear_gen_statem_handler | Modules]}
      <- supervisor:which_children(?SERVER), Pid =/= undefined].

%% @doc Starts the supervisor
-spec(start_link() -> {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%% @private
%% @doc Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
-spec(init(Args :: term()) ->
  {'ok', {#{'intensity' := pos_integer(),
            'period' := pos_integer(),
            'strategy' := 'one_for_one'}, []}}).
init([]) ->
  MaxRestarts = 10000,
  MaxSecondsBetweenRestarts = 60,
  SupFlags = #{strategy => one_for_one,
               intensity => MaxRestarts,
               period => MaxSecondsBetweenRestarts},

  {ok, {SupFlags, []}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

child_spec(Name, Module, Args) ->
  #{id => Name,
    start => {'bear_gen_statem_handler', start_link, [Name, Module, Args]},
    restart => transient,
    shutdown => 5000,
    type => worker,
    modules => ['bear_gen_statem_handler', Module]}.

child_spec(Name, Module) ->
  child_spec(Name, Module, undefined).