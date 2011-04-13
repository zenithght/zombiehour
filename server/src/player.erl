-module(player).
-behavior(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([create/1]).

create(Attrs) ->
  gen_server:start_link(?MODULE, Attrs, []).

build_map(Player) ->
  ScenarioMap = dict:fetch(map, Player),
  VisibleTiles = dict:fetch(visible_tiles, Player),
  KnownTiles = dict:fetch(known_tiles, Player),
  {X,Y} = nav:position(dict:fetch(location, Player)),
  lists:flatten(
  lists:map(
    fun(Row) ->
        %traverse cols...
        lists:flatten(
        lists:map(
          fun(Col) ->
              Key = tile:coords_to_key( Col, Row ),
              case lists:member(Key, VisibleTiles) of
                false ->
                  case lists:keyfind(Key, 1, KnownTiles) of
                    false ->
                      "0,";
                    {Key, Mem} ->
                      lists:concat([Mem,","])
                  end;
                true ->
                  {Key, Tile} = digraph:vertex(ScenarioMap, Key),
                  lists:concat([dict:fetch(symbol, Tile), ","])
              end
          end,
          lists:seq(X-12,X+12)))
    end,
    lists:seq(Y-12,Y+12))).

learn_tiles(Map, Tiles) ->
  lists:keysort(1, lists:map(
    fun(Key) ->
        {Key, Tile} = digraph:vertex(Map, Key),
        Sym = integer_to_list(list_to_integer(dict:fetch(symbol, Tile))+8),
        {Key, Sym}
    end,
    Tiles)).

queue_to_string([]) ->
  "ready";

queue_to_string(Queue) ->
  lists:flatmap(
    fun({Action, {player, Value}}) ->
        lists:concat([atom_to_list(Action), " ", Value, "<br />"])
    end,
    Queue).


update_queue(Player, Request) ->
  case Request of
    nil ->
      Player;
    Request ->
      Queue = dict:fetch(queue, Player),
      case Queue of
        [] ->
          NewQueue = [Request];
        _ ->
          NewQueue = lists:append(Queue, [Request])
      end,
      QS = queue_to_string(NewQueue),
      Player1 = dict:store(queuestring, QS, Player),
      dict:store(queue, NewQueue, Player1)
  end.

do_request(Scenario, Player, {Action, {player, Value}}) ->
  case dict:fetch(hp, Player) > 0 of
    true ->
      gen_server:cast(Scenario, {Action, {Player, Value}});
    false ->
      ok
  end.

update_stat(Atom, {F, M, Stat}) ->
  {F,M, [Atom|Stat]}.

init([Name, Scenario, Map, Location]) ->
  Attrs = [{id, self()}, {tag, Name}, {queue, []}, {cooldown, 0}, {hp, 20},
    {map, Map}, {ammo, 10},
    {visible_tiles, []}, {known_tiles, []}, {locked, false}, {sight, 8}, {zombified, false}],
  Player = dict:from_list(Attrs),
  gen_server:cast(self(), {update_character, {location, Location}}),
  Update = {[],[],[tag,hp,ammo]},
  Addresses = {inactive, Scenario},
  {ok, {Player, Update, Addresses}}.

handle_call(character, _From, {Player, U, A}) ->
  {reply, Player, {Player, U, A}};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(tick, {Player, Update, {Address, Scenario}}) ->
  Num = dict:fetch(cooldown, Player),
  case Num of
    0 ->
      case dict:fetch(locked, Player) of
        true ->
          Update1 = Update,
          NewPlayer = Player;
        false ->
          case dict:fetch(queue, Player) of
            [] ->
              Update1 = Update,
              NewPlayer = Player;
            [Request|NewQueue] ->
              do_request(Scenario, Player, Request),
              Player1 = dict:store(locked, true, Player),
              QS = queue_to_string(NewQueue),
              Player2 = dict:store(queuestring, QS, Player1),
              Update1 = update_stat(queuestring, Update),
              NewPlayer = dict:store(queue, NewQueue, Player2)
          end
      end;
    Num ->
      Update1 = update_stat(cooldown, Update),
      NewPlayer = dict:update_counter(cooldown, -1, Player)
  end,
  case Address of
    inactive ->
      NewAddress = Address,
      NewUpdate = Update1;
    Address ->
      {Feedback, Map, Stats} = Update1,
      Map2 = build_map(NewPlayer),
      case Map2 == Map of
        true ->
          MapData = "nil",
          NewMap  = Map;
        false ->
          MapData = Map2,
          NewMap  = Map2
      end,
      NewFeedback = [],
      case Feedback of
        [] ->
          FeedbackMsg = "nil";
        FeedbackMsg ->
          ok
      end,
      NewStats = [],
      case Stats of
        [] ->
          StatData = "nil";
        Stats ->
          StatData = lists:map(
            fun(Stat) ->
                lists:concat([Stat,",",dict:fetch(Stat, NewPlayer),";"])
            end,
            Stats)
      end,

      %Data = lists:concat(["name,",dict:fetch(tag, NewPlayer)]),
      case MapData == "nil" andalso StatData == "nil" andalso FeedbackMsg == "nil" of
        true ->
          NewAddress = Address;
        false ->
          JSON =
          %lists:concat(["{\"map\":\"",Map,"\",\"flash\":\"",Num,"\",\"data\":\"",Data,"\",\"msg\":\"",Msg,"\"}"]),
          lists:concat(["{\"map\":\"",MapData,"\",\"data\":\"",StatData,"\",\"msg\":\"",FeedbackMsg,"\"}"]),
          NewAddress = inactive,
          Address ! JSON
      end,
      NewUpdate = {NewFeedback, NewMap, NewStats}
  end,
  {noreply, {NewPlayer, NewUpdate, {NewAddress, Scenario}}};

handle_cast({update_character, {Attr, Value}}, {Player, U, A}) ->
  case Attr of
    location ->
      P1 = dict:store(Attr, Value, Player),
      VisibleTiles = los:character_los(P1),
      P2 = dict:store(visible_tiles, VisibleTiles, P1),
      OldKnownTiles = dict:fetch(known_tiles, Player),
      Map = dict:fetch(map, Player),
      KnownTiles = lists:ukeymerge(1, learn_tiles(Map, VisibleTiles), OldKnownTiles),
      NewPlayer = dict:store(known_tiles, KnownTiles, P2);
    _ ->
      NewPlayer = dict:store(Attr, Value, Player)
  end,
  {noreply, {NewPlayer, U, A}};

handle_cast({take_damage, Amt}, {Player, U, {A, Scenario}}) ->
  NewPlayer = dict:update_counter(hp, -Amt, Player),
  NewUpdate = update_stat(hp, U),
  case dict:fetch(hp, NewPlayer) >= 1 of
    true ->
      gen_server:cast(Scenario, {update_self, NewPlayer});
    false ->
      gen_server:cast(Scenario, {die, NewPlayer})
  end,
  {noreply, {NewPlayer, NewUpdate, {A, Scenario}}};

handle_cast({msg, Msg}, {P, {Feedback, M, S}, A}) ->
  NewFeedback = lists:concat([Feedback,"<span class='combat_msg'>", Msg, "</span><br/>"]),
  {noreply, {P, {NewFeedback, M, S}, A}};

handle_cast({hear, Msg}, {P, {Feedback, M, S}, A}) ->
  NewFeedback = lists:concat([Feedback, Msg, "<br/>"]),
  {noreply, {P, {NewFeedback, M, S}, A}};

handle_cast({return_address, Address}, {P, U, {_, S}}) ->
  {noreply, {P, U, {Address, S}}};

handle_cast({heat_up, Amount}, {Player, U, A}) ->
  NewPlayer = dict:update_counter(cooldown, Amount, Player),
  {noreply, {NewPlayer, U, A}};

handle_cast({lose_ammo, Amount}, {Player, U, A}) ->
  NewPlayer = dict:update_counter(ammo, -Amount, Player),
  NewUpdate = update_stat(ammo, U),
  {noreply, {NewPlayer, NewUpdate, A}};

handle_cast(update_all, {Player, {F, _Map, _Stats}, A}) ->
  Stats = [tag, ammo, hp],
  {noreply, {Player, {F, [], Stats}, A}};


handle_cast({post, {Param, Value}}, {Player, U, {_, Scenario} = A}) ->
  case Param of
    "say" ->
      Request = nil,
      gen_server:cast(Scenario, {say, {Player, Value}});
    "walk" ->
      Request = {walk, {player, Value}};
    "shoot" ->
      Request = {shoot, {player, Value}};
    Param ->
      Request = nil,
      io:format("{ ~p, ~p }: failed to match anything.~n",[Param, Value])
  end,
  NewPlayer = update_queue(Player, Request),
  NewUpdate = update_stat(queuestring, U),
  {noreply, {NewPlayer, NewUpdate, A}};

handle_cast(unlock, {Player, U, A}) ->
  NewPlayer = dict:store(locked, false, Player),
  {noreply, {NewPlayer, U, A}};

handle_cast(Msg, State) ->
  io:format("cast received: ~p, When state was: ~p~n",[Msg, State]),
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
