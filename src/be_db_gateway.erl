-module(be_db_gateway).

-include("be_db_follower.hrl").
-include("be_db_worker.hrl").

-export([prepare_conn/1]).
%% be_block_handler
-export([init/1, load_block/6]).
%% hooks
-export([incremental_commit_hook/1, end_commit_hook/2]).
%% api
-export([calculate_location_hex/1]).

-behavior(be_db_worker).
-behavior(be_db_follower).

-record(state, {}).

-define(S_INSERT_GATEWAY, "insert_gateway").
-define(S_UNHANDLED_GATEWAY_LOOKUP, "lookup_unhandled_gateway").

%%
%% be_db_worker
%%

prepare_conn(Conn) ->
    {ok, S1} =
        epgsql:parse(
            Conn,
            ?S_INSERT_GATEWAY,
            [
                "insert into gateways (block, time, address, owner, location, last_poc_challenge, last_poc_onion_key_hash, witnesses, nonce, name, reward_scale, elevation, gain, location_hex, mode) select ",
                "$1 as block, ",
                "$2 as time, ",
                "$3 as address, ",
                "$4 as owner, ",
                "$5 as location, ",
                "$6 as last_poc_challenge, ",
                "$7 as last_poc_onion_key_hash, ",
                "$8 as witnesses, ",
                "$9 as nonce, ",
                "$10 as name, ",
                "$11 as reward_scale, ",
                "$12 as elevation, ",
                "$13 as gain, ",
                "$14 as location_hex, ",
                "$15 as mode; "
            ],
            []
        ),
    {ok, S2} =
        epgsql:parse(
            Conn,
            ?S_UNHANDLED_GATEWAY_LOOKUP,
            ["select reward_scale from gateway_inventory where address = $1"],
            []
        ),

    #{
        ?S_INSERT_GATEWAY => S1,
        ?S_UNHANDLED_GATEWAY_LOOKUP => S2
    }.

%%
%% be_block_handler
%%

init(_) ->
    BaseDir = application:get_env(blockchain, base_dir, "data"),
    dets:open_file(?MODULE, [{file, filename:join(BaseDir, ?MODULE)}]),
    {ok, #state{}}.

load_block(Conn, _Hash, Block, _Sync, Ledger, State = #state{}) ->
    %% Construct the list of gateways that have changed in this block based on
    %% transaction actors

    StartActor = erlang:monotonic_time(millisecond),
    BlockGateways = be_db_follower:fold_actors(
        [
            "gateway",
            "reward_gateway",
            "witness",
            "challenger",
            "challengee",
            "packet_receiver",
            %% TODO: Remove for validators
            "consensus_member"
        ],
        fun({_Role, Key}, Acc) ->
            maps:put(Key, true, Acc)
        end,
        #{},
        Block
    ),
    be_db_follower:maybe_log_duration(db_gateway_actor_fold, StartActor),

    BlockHeight = blockchain_block_v1:height(Block),
    BlockTime = blockchain_block_v1:time(Block),
    ChangeType =
        case block_contains_election(Block) of
            true -> election;
            false -> block
        end,

    %% Merge in any gateways that are indirectly updated by the ledger and stashed
    %% in the module ets table
    StartUnhandled = erlang:monotonic_time(millisecond),
    Gateways =
        dets:foldl(
            fun
                ({Key}, Acc) ->
                    case should_process_unhandled(Key, Acc, ChangeType, Ledger) of
                        true ->
                            lager:debug("processing unhandled gateway ~p", [?BIN_TO_B58(Key)]),
                            maps:put(Key, true, Acc);
                        false ->
                            Acc
                    end;
                (_, Acc) ->
                    Acc
            end,
            BlockGateways,
            ?MODULE
        ),
    be_db_follower:maybe_log_duration(db_gateway_unhandled_fold, StartUnhandled),

    StartMkQuery = erlang:monotonic_time(millisecond),
    Queries = maps:fold(
        fun(Key, _Value, Acc) ->
            case blockchain_ledger_v1:find_gateway_info(Key, Ledger) of
                {ok, GW} ->
                    Query =
                        q_insert_gateway(
                            BlockHeight,
                            BlockTime,
                            Key,
                            GW,
                            ChangeType,
                            Ledger
                        ),
                    [Query | Acc];
                {error, _} ->
                    Acc
            end
        end,
        [],
        Gateways
    ),
    be_db_follower:maybe_log_duration(db_gateway_query_make, StartMkQuery),

    StartQuery = erlang:monotonic_time(millisecond),
    ok = ?BATCH_QUERY(Conn, Queries),
    be_db_follower:maybe_log_duration(db_gateway_query_exec, StartQuery),

    dets:delete_all_objects(?MODULE),
    {ok, State}.

should_process_unhandled(Address, Cache, ChangeType, Ledger) ->
    case maps:is_key(Address, Cache) of
        true ->
            false;
        false ->
            case blockchain_ledger_v1:find_gateway_info(Address, Ledger) of
                {ok, GW} ->
                    B58Address = ?BIN_TO_B58(Address),
                    LedgerMode = blockchain_ledger_gateway_v2:mode(GW),
                    LedgerLocation = blockchain_ledger_gateway_v2:location(GW),
                    {ok, _, [{RewardScale}]} = ?PREPARED_QUERY(
                        ?S_UNHANDLED_GATEWAY_LOOKUP,
                        [B58Address]
                    ),
                    % Technically only reward scale is changed in the ledger
                    % without gateway tagged data in a block
                    case
                        RewardScale ==
                            reward_scale(LedgerLocation, ChangeType, LedgerMode, Ledger)
                    of
                        true -> false;
                        _ -> true
                    end;
                _ ->
                    false
            end
    end.

reward_scale(Location, ChangeType, Mode, Ledger) ->
    case ChangeType of
        block ->
            undefined;
        election ->
            ?MAYBE_FN(
                fun(L) ->
                    %% Only insert scale value for "full | light" gateways
                    case {Mode, blockchain_hex:scale(L, Ledger)} of
                        {full, {ok, V}} -> blockchain_utils:normalize_float(V);
                        {light, {ok, V}} -> blockchain_utils:normalize_float(V);
                        _ -> undefined
                    end
                end,
                Location
            )
    end.

q_insert_gateway(BlockHeight, BlockTime, Address, GW, ChangeType, Ledger) ->
    B58Address = ?BIN_TO_B58(Address),
    {ok, Name} = erl_angry_purple_tiger:animal_name(B58Address),
    Mode = blockchain_ledger_gateway_v2:mode(GW),
    Location = blockchain_ledger_gateway_v2:location(GW),
    RewardScale = reward_scale(Location, ChangeType, Mode, Ledger),
    Params = [
        BlockHeight,
        BlockTime,
        B58Address,
        ?BIN_TO_B58(blockchain_ledger_gateway_v2:owner_address(GW)),
        ?MAYBE_H3(Location),
        ?MAYBE_UNDEFINED(blockchain_ledger_gateway_v2:last_poc_challenge(GW)),
        ?MAYBE_B64(blockchain_ledger_gateway_v2:last_poc_onion_key_hash(GW)),
        witnesses_to_json(blockchain_ledger_gateway_v2:witnesses(GW)),
        blockchain_ledger_gateway_v2:nonce(GW),
        Name,
        RewardScale,
        blockchain_ledger_gateway_v2:elevation(GW),
        blockchain_ledger_gateway_v2:gain(GW),
        ?MAYBE_H3(?MAYBE_FN(fun calculate_location_hex/1, Location)),
        blockchain_ledger_gateway_v2:mode(GW)
    ],
    {?S_INSERT_GATEWAY, Params}.

-define(H3_LOCATION_RES, 8).

-spec calculate_location_hex(h3:h3index()) -> h3:h3index().
calculate_location_hex(Location) ->
    h3:parent(Location, ?H3_LOCATION_RES).

witnesses_to_json(Witnesses) ->
    maps:fold(
        fun(Key, Witness, Acc) ->
            Acc#{?BIN_TO_B58(Key) => witness_to_json(Witness)}
        end,
        #{},
        Witnesses
    ).

witness_to_json(Witness) ->
    #{
        <<"histogram">> => blockchain_ledger_gateway_v2:witness_hist(Witness),
        <<"first_time">> => ?MAYBE_FN(
            fun(V) -> integer_to_binary(V) end,
            blockchain_ledger_gateway_v2:witness_first_time(Witness)
        ),
        <<"recent_time">> => ?MAYBE_FN(
            fun(V) -> integer_to_binary(V) end,
            blockchain_ledger_gateway_v2:witness_recent_time(Witness)
        )
    }.

-spec block_contains_election(blockchain_block:block()) -> boolean().
block_contains_election(Block) ->
    lists:any(
        fun(Txn) -> blockchain_txn:type(Txn) == blockchain_txn_consensus_group_v1 end,
        blockchain_block:transactions(Block)
    ).

incremental_commit_hook(_Changes) ->
    ok.

end_commit_hook(_CF, Changes) ->
    Keys = lists:filtermap(
        fun
            ({put, Key}) -> {true, {Key}};
            (_) -> false
        end,
        Changes
    ),
    dets:insert(?MODULE, Keys).
