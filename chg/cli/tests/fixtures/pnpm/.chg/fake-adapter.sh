#!/bin/sh
# Stand-in adapter for chg's integration tests. FAKE_MODE selects a misbehaviour.
cmd=$1; shift
echo "Compiling 2 files (.ex)"   # build noise on stdout, as mix prints it
case "${FAKE_MODE:-ok}" in
  malformed) echo '{"mode":"subset","reason":"x"}'; exit 0 ;;
  garbage)   echo 'this is not json'; exit 0 ;;
  silent)    exit 0 ;;
  crash)     echo '{"mode":"subset","reason":"stale","tests":["test/a_test.exs"]}'; exit 3 ;;
  sleep)     sleep 30; exit 0 ;;
  hang)      echo "Compiling step 7"; sleep 30; exit 0 ;;
  fail0)     echo '{"ok":false,"failures":[{"check":"format","message":"x"}]}'; exit 0 ;;
  orphan)    sleep 30 & echo $! > .chg/orphan.pid; echo '{"work":"none","ms":1}'; exit 0 ;;
esac
case "$cmd" in
  snapshot) echo '{"work":"none","ms":3}' ;;
  static)   echo '{"ok":true,"failures":[]}' ;;
  affected) echo "{\"mode\":\"subset\",\"reason\":\"changed since $1\",\"tests\":[\"test/a_test.exs\",\"test/b c_test.exs\"]}" ;;
  run)      if [ "$1" = "fail.txt" ]; then
              echo '{"results":[{"id":"test/a_test.exs:3","status":"fail","ms":5}]}'; exit 1
            fi
            echo "{\"results\":[{\"id\":\"$1@${MIX_TEST_PARTITION:-none}\",\"status\":\"pass\",\"ms\":5}]}" ;;
  shard)    echo "{\"results\":[{\"id\":\"shard-$2-of-$1\",\"status\":\"pass\",\"ms\":1}]}" ;;
esac
