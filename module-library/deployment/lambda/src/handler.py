"""Placeholder Lambda handler. Replace this folder with your own code,
or point the lambda_source_dir variable at your source directory."""
import json
import os


def lambda_handler(event, context):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "message": "Hello from the generated Lambda template",
                "environment": os.environ.get("ENVIRONMENT", "unknown"),
            }
        ),
    }
