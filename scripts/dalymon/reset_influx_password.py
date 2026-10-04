#!/usr/bin/env python3
"""Reset an InfluxDB 2.x user's password using an all-access token."""

from __future__ import annotations

import argparse
import getpass
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path


def load_token(token_file: Path) -> str:
    return token_file.read_text(encoding="utf-8").strip()


def api_request(url: str, token: str, method: str = "GET", body: dict | None = None) -> bytes:
    headers = {
        "Authorization": f"Token {token}",
        "Accept": "application/json",
    }
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")

    request = urllib.request.Request(url, headers=headers, data=data, method=method)
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read()


def find_user_id(base_url: str, token: str, user_name: str) -> tuple[str, str]:
    payload = json.loads(api_request(f"{base_url}/api/v2/users", token).decode("utf-8"))
    for user in payload.get("users", []):
        if user.get("name") == user_name:
            return user["id"], user["name"]
    raise SystemExit(f'User named "{user_name}" not found.')


def reset_password(base_url: str, token: str, user_id: str, new_password: str) -> None:
    body = {"password": new_password}
    url = f"{base_url}/api/v2/users/{user_id}/password"

    for method in ("POST", "PATCH"):
        try:
            api_request(url, token, method=method, body=body)
            return
        except urllib.error.HTTPError as error:
            # Some InfluxDB builds only allow one of these methods.
            if error.code in {404, 405}:
                continue
            message = error.read().decode("utf-8", errors="replace")
            raise SystemExit(f"Password reset failed: HTTP {error.code}: {message}") from error

    raise SystemExit("Password reset failed: both POST and PATCH were rejected.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Reset an InfluxDB user password")
    parser.add_argument("--url", default="http://localhost:8086", help="InfluxDB base URL")
    parser.add_argument(
        "--token-file",
        default="all-access-token.txt",
        type=Path,
        help="Path to an all-access token file",
    )
    parser.add_argument("--user", required=True, help="Exact InfluxDB user name")
    parser.add_argument(
        "--password",
        help="New password. If omitted, you will be prompted securely.",
    )

    args = parser.parse_args()
    token = load_token(args.token_file)
    new_password = args.password or getpass.getpass("New password: ")

    user_id, user_name = find_user_id(args.url, token, args.user)
    reset_password(args.url, token, user_id, new_password)

    print(f"Password reset for {user_name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())