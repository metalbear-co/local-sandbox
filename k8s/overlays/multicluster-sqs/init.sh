#!/bin/bash
awslocal sqs create-queue --queue-name test-queue --region us-east-1
echo "LocalStack initialized: test-queue created"
