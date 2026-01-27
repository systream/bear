%%%-------------------------------------------------------------------
%% @doc bear top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(bear_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 30,
                 period => 3},
    ChildSpecs = [
      #{id => bear_gen_statem_sup,
        start => {'bear_gen_statem_sup', start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => ['bear_gen_statem_sup', 'bear_gen_statem_handler']},
      #{id => bear_gen_statem_manager,
        start => {'bear_gen_statem_manager', start_link, []},
        restart => permanent,
        shutdown => 300000,
        type => worker,
        modules => ['bear_gen_statem_manager', 'bear_gen_statem_sup', 'bear_gen_statem_handler']}
    ],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
