#!/bin/bash

USER=$1
SQUEUE_CMD="squeue"
if [ ! -z "$USER" ]; then
    SQUEUE_CMD="squeue -u $USER"
fi

let "a = 0"

while [[ "$(squeue | grep $JOB_PID)" != "" ]]
do
  if [[ $((a % 5)) == 0 ]]; then
    $SQUEUE_CMD -l
    $SQUEUE_CMD -l --start
  fi

  cat ${OUT_FILE} | tail -n 15
  echo "Still running..."
  sleep 60
  let "a = a + 1"
done
