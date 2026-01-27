-module(bear_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([simple_start_test/1, call_test/1, cast_test/1, stop_test/1]).

%% persistence tests
-export([persistence_save_test/1, persistence_restore_test/1, persistence_cleanup_test/1]).
-export([handoff_test/1]).

all() ->
    [
        simple_start_test,
        call_test,
        cast_test,
        stop_test,
        persistence_save_test,
        persistence_restore_test,
        persistence_cleanup_test,
        handoff_test
    ].

init_per_suite(Config) ->

    Keeper = spawn(fun() ->
      ets:new(rico_mock_store, [named_table, public, set]),
      receive
        stop -> ok
      end
    end),

    meck:new(rico, [non_strict, no_link, unstick, passthrough]),
    meck:expect(rico, new_obj, fun(_Bucket, Key, Data) -> {mock_obj, Key, Data} end),
    meck:expect(rico, value, fun({mock_obj, _Key, Data}) -> Data end),
    meck:expect(rico, value, fun({mock_obj, Key, _OldData}, NewData) -> {mock_obj, Key, NewData} end),
    meck:expect(rico, fetch, fun(_Bucket, Key) ->
        case ets:lookup(rico_mock_store, Key) of
            [{Key, Obj}] -> {ok, Obj};
            [] -> not_found
        end
    end),
    meck:expect(rico, store, fun({mock_obj, Key, _Data} = Obj) ->
        ets:insert(rico_mock_store, {Key, Obj}),
        {ok, Obj}
    end),
    meck:expect(rico, remove, fun
        (undefined) ->
            ok;
        ({mock_obj, Key, _Data}) ->
            ets:delete(rico_mock_store, Key),
            ok
    end),
    {ok, _} = application:ensure_all_started(bear),

    [{rico_mock_keeper, Keeper} | Config].

end_per_suite(Config) ->
    [bear:stop(Id) || {Id, _Pid, _Module} <- bear_gen_statem_sup:children()],
    ?config(rico_mock_keeper, Config) ! stop,
    meck:unload(rico),
    application:stop(pes),
    ok.

init_per_testcase(_TestCase, Config) ->
    ets:delete_all_objects(rico_mock_store),
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

simple_start_test(_Config) ->
    Id = <<"test_1">>,
    {ok, Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    true = is_process_alive(Pid),
    ok.

call_test(_Config) ->
    Id = <<"test_2">>,
    {ok, _Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:call(Id, {set_data, 123}),
    123 = bear:call(Id, get_data),
    ok.

cast_test(_Config) ->
    Id = <<"test_3">>,
    {ok, _Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:cast(Id, {set_data_cast, 456}),
    timer:sleep(50),
    456 = bear:call(Id, get_data),
    ok.

stop_test(_Config) ->
    Id = <<"test_4">>,
    {ok, Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:stop(Id),
    timer:sleep(100),
    false = is_process_alive(Pid),
    ok.

persistence_save_test(_Config) ->
    Id = <<"test_5">>,
    {ok, _Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:call(Id, {set_data_and_save, 789}),
    timer:sleep(50),
    Key = term_to_binary({bear_test_handler, Id}),
    [{Key, {mock_obj, Key, SavedData}}] = ets:lookup(rico_mock_store, Key),
    true = is_binary(SavedData),
    ok.

persistence_restore_test(_Config) ->
    Id = <<"test_6">>,
    {ok, _Pid1} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:call(Id, {set_data_and_save, keep_me}),
    ok = bear:stop(Id),
    timer:sleep(100),

    Key = term_to_binary({bear_test_handler, Id}),
    [{Key, _}] = ets:lookup(rico_mock_store, Key),

    {ok, _Pid2} = bear:start_link(Id, bear_test_handler, [Id]),
    keep_me = bear:call(Id, get_data),
    ok.

persistence_cleanup_test(_Config) ->
    Id = <<"test_7">>,
    {ok, _Pid} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:call(Id, {set_data_and_save, ephemeral}),
    ok = bear:stop(Id),
    timer:sleep(100),

    Key = term_to_binary({bear_test_handler, Id}),
    [] = ets:lookup(rico_mock_store, Key),

    {ok, _Pid2} = bear:start_link(Id, bear_test_handler, [Id]),
    undefined = bear:call(Id, get_data),
    ok.

handoff_test(_Config) ->
    Id = <<"test_handoff">>,
    %% Start first process
    {ok, Pid1} = bear:start_link(Id, bear_test_handler, [Id]),
    ok = bear:call(Id, {set_data, 999}),
    999 = bear:call(Id, get_data),

    %% Initiate handoff
    ok = bear_gen_statem_handler:handoff(Id),
    timer:sleep(100),

    {ok, Pid2} = bear_gen_statem_handler:start_link(Id, bear_test_handler, undefined),

    %% Wait for Pid1 to die
    Ref = monitor(process, Pid1),
    receive
        {'DOWN', Ref, process, Pid1, _Reason} ->
            ok
    after 5000 ->
        ct:fail(timeout_waiting_for_handoff)
    end,

    true = is_process_alive(Pid2),
    999 = bear:call(Id, get_data),
    Pid2 = pes:whereis_name(Id),
    ok.
