#!/bin/bash
awslocal sqs create-queue --queue-name TestQueue --region eu-north-1
echo "LocalStack initialized: TestQueue created"

