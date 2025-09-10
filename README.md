bear
=====

rp([bear_gen_statem_manager:start_handler(<<"test_", (integer_to_binary(I))/binary>>, test_callb, [I+I]) || I <- lists:seq(1, 100)]).
rp([gen_statem:call({via, pes, <<"test_", (integer_to_binary(I))/binary>>}, {set, I+I*I}) || I <- lists:seq(1, 100)]).

Build
-----

    $ rebar3 compile
