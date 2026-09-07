#!/usr/bin/python3
"""Local JSON-RPC test double. Never accesses Codex, auth files, or the network."""
import json
import os
import sys
import time

scenario = sys.argv[1] if len(sys.argv) > 1 else "success"
if len(sys.argv) > 2:
    with open(sys.argv[2], "w") as f:
        f.write(str(os.getpid()))

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    response = {"id": request["id"]}
    if method == "initialize":
        response["result"] = {"userAgent": "Test"}
    elif method == "account/read":
        response["result"] = {"account": None if scenario == "signed-out" else {
            "type": "apikey" if scenario == "api-key" else "chatgpt",
            "email": "test@example.invalid", "planType": "pro"}}
    elif method == "account/rateLimits/read":
        if scenario == "timeout":
            time.sleep(30)
        if scenario == "disconnect":
            sys.exit(0)
        if scenario == "invalid":
            print("not json", flush=True)
            continue
        if scenario == "auth-expired":
            response["error"] = {"code": 401, "message": "Unauthorized"}
        else:
            response["result"] = {"rateLimitsByLimitId": {"codex": {
                "primary": {"usedPercent": 36, "windowDurationMins": 10080, "resetsAt": 1900000000}
            }}, "rateLimitResetCredits": {"availableCount": 2, "credits": [
                {"status": "available", "expiresAt": None},
                {"status": "available", "expiresAt": 1900000000}]}}
    elif method == "account/usage/read":
        if scenario == "unsupported-stats":
            response["error"] = {"code": -32600, "message": "Invalid request: unknown variant `account/usage/read`"}
        elif scenario == "invalid-stats":
            response["result"] = {"summary": {"lifetimeTokens": "invalid"}}
        else:
            response["result"] = {"summary": {"lifetimeTokens": 1234},
                                  "dailyUsageBuckets": [{"startDate": "2026-09-07", "tokens": 1234}]}
    else:
        response["error"] = {"code": -32601, "message": "Method not found"}
    # Real transports interleave notifications, and do not preserve write boundaries.
    print(json.dumps({"method": "account/updated", "params": {"authMode": "chatgpt"}}), flush=True)
    encoded = json.dumps(response) + "\n"
    midpoint = len(encoded) // 2
    sys.stdout.write(encoded[:midpoint])
    sys.stdout.flush()
    time.sleep(0.002)
    sys.stdout.write(encoded[midpoint:])
    sys.stdout.flush()
