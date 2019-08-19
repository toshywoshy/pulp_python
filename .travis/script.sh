#!/usr/bin/env bash
# coding=utf-8

# WARNING: DO NOT EDIT!
#
# This file was generated by plugin_template, and is managed by bootstrap.py. Please use
# bootstrap.py to update this file.
#
# For more info visit https://github.com/pulp/plugin_template

set -mveuo pipefail

export POST_SCRIPT=$TRAVIS_BUILD_DIR/.travis/post_script.sh
export POST_DOCS_TEST=$TRAVIS_BUILD_DIR/.travis/post_docs_test.sh
export FUNC_TEST_SCRIPT=$TRAVIS_BUILD_DIR/.travis/func_test_script.sh

# Needed for both starting the service and building the docs.
# Gets set in .travis/settings.yml, but doesn't seem to inherited by
# this script.
export DJANGO_SETTINGS_MODULE=pulpcore.app.settings

wait_for_pulp() {
  TIMEOUT=${1:-5}
  while [ "$TIMEOUT" -gt 0 ]
  do
    echo -n .
    sleep 1
    TIMEOUT=$(($TIMEOUT - 1))
    if [ "$(http :24817/pulp/api/v3/status/ 2>/dev/null | jq '.database_connection.connected and .redis_connection.connected')" = "true" ]
    then
      echo
      return
    fi
  done
  echo
  return 1
}

if [ "$TEST" = 'docs' ]; then
  sleep 5
  cd docs
  make html
  cd ..

  if [ -f $POST_DOCS_TEST ]; then
      $POST_DOCS_TEST
  fi
  exit
fi

if [ "$TEST" = 'bindings' ]; then
  COMMIT_MSG=$(git log --format=%B --no-merges -1)
  export PULP_BINDINGS_PR_NUMBER=$(echo $COMMIT_MSG | grep -oP 'Required\ PR:\ https\:\/\/github\.com\/pulp\/pulp-openapi-generator\/pull\/(\d+)' | awk -F'/' '{print $7}')

  cd ..
  git clone https://github.com/pulp/pulp-openapi-generator.git
  cd pulp-openapi-generator

  if [ -n "$PULP_BINDINGS_PR_NUMBER" ]; then
    git fetch origin +refs/pull/$PULP_BINDINGS_PR_NUMBER/merge
    git checkout FETCH_HEAD
  fi

  ./generate.sh pulpcore python
  pip install ./pulpcore-client
  ./generate.sh pulp_python python
  pip install ./pulp_python-client

  python $TRAVIS_BUILD_DIR/.travis/test_bindings.py

  if [ ! -f $TRAVIS_BUILD_DIR/.travis/test_bindings.rb ]
  then
    exit
  fi

  rm -rf ./pulpcore-client

  ./generate.sh pulpcore ruby
  cd pulpcore-client
  gem build pulpcore_client
  gem install --both ./pulpcore_client-0.gem
  cd ..

  rm -rf ./pulp_python-client

  ./generate.sh pulp_python ruby

  cd pulp_python-client
  gem build pulp_python_client
  gem install --both ./pulp_python_client-0.gem
  cd ..

  ruby $TRAVIS_BUILD_DIR/.travis/test_bindings.rb
  exit
fi

# Run unit tests.
coverage run $(which django-admin) test ./pulp_python/tests/unit/

# Run functional tests, and upload coverage report to codecov.
show_logs_and_return_non_zero() {
    readonly local rc="$?"

    for logfile in "~/django_runserver.log" "~/content_app.log" "~/resource_manager.log" "~/reserved_worker-1.log"
    do
      echo -en "travis_fold:start:$logfile"'\\r'
      cat $logfile
      echo -en "travis_fold:end:$logfile"'\\r'
    done

    return "${rc}"
}

# Stop services started by ansible roles
sudo systemctl stop pulp-worker* pulp-resource-manager pulp-content-app pulp-api

# Start services with logs and coverage
export PULP_CONTENT_HOST=localhost:24816
rq worker -n 'resource-manager@%h' -w 'pulpcore.tasking.worker.PulpWorker' -c 'pulpcore.rqconfig' >> ~/resource_manager.log 2>&1 &
rq worker -n 'reserved-resource-worker-1@%h' -w 'pulpcore.tasking.worker.PulpWorker' -c 'pulpcore.rqconfig' >> ~/reserved_worker-1.log 2>&1 &
gunicorn pulpcore.tests.functional.content_with_coverage:server --bind 'localhost:24816' --worker-class 'aiohttp.GunicornWebWorker' -w 2 >> ~/content_app.log 2>&1 &
coverage run $(which django-admin) runserver 24817 --noreload >> ~/django_runserver.log 2>&1 &
wait_for_pulp 20

# Run functional tests
if [ -f $FUNC_TEST_SCRIPT ]; then
    $FUNC_TEST_SCRIPT
else
    pytest -v -r sx --color=yes --pyargs pulp_python.tests.functional || show_logs_and_return_non_zero
fi


if [ -f $POST_SCRIPT ]; then
    $POST_SCRIPT
fi
