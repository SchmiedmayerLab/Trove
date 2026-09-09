"""Exercise real Keycloak rollover and bounded JWKS trust on an owned local stack.

Uses normal server cache lifetimes and HTTP authentication, not injected keys or
a test clock. Mutates only the realm created by the disposable checkpoint.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import base64
from dataclasses import dataclass
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from verify_process_restart import Checkpoint, add_stack_arguments, request, require, run_verification


@dataclass(frozen=True)
class FixtureToken:
    bearer: str
    key: str
    expires_at: int

    @classmethod
    def inspect(cls, bearer: str) -> "FixtureToken":
        # Inspection establishes test preconditions, never application authorization.
        require(isinstance(bearer, str) and len(bearer) <= 16384, "Invalid fixture token")
        parts = bearer.split(".")
        require(len(parts) == 3 and all(parts), "Invalid fixture token framing")
        header, claims = [json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))) for part in parts[:2]]
        require(isinstance(header, dict) and header.get("alg") == "RS256", "Fixture must use RS256")
        key = header.get("kid")
        require(isinstance(key, str) and 0 < len(key) <= 256, "Invalid fixture signing-key identifier")
        require(isinstance(claims, dict) and type(claims.get("exp")) is int, "Invalid fixture expiry")
        return cls(bearer, key, claims["exp"])


def key_provider(metadata: object, key: str) -> str:
    require(isinstance(metadata, dict) and isinstance(metadata.get("keys"), list), "Invalid key inventory")
    matches = [item for item in metadata["keys"] if isinstance(item, dict) and item.get("kid") == key]
    require(len(matches) == 1 and matches[0].get("algorithm") == "RS256", "Expected exactly one signing-key provider")
    provider = matches[0].get("providerId")
    require(isinstance(provider, str), "Missing signing-key provider")
    return str(uuid.UUID(provider))


def probe(api: str, token: FixtureToken) -> int:
    call = urllib.request.Request(api + "/participant/enrollments", headers={"Authorization": "Bearer " + token.bearer})
    try:
        with urllib.request.urlopen(call, timeout=10) as response:
            require(response.status == 200 and json.loads(response.read(2049)) == [], "Unexpected protected response")
            return response.status
    except urllib.error.HTTPError as error:
        with error:
            error.read(2049)
            return error.code


def await_status(api: str, token: FixtureToken, expected: int, transient: int, timeout: float) -> float:
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        status = probe(api, token)
        if status == expected:
            return time.monotonic() - started
        require(status == transient, f"Unexpected authentication status {status}; expected {expected} or transient {transient}")
        time.sleep(1)
    raise RuntimeError(f"Authentication did not reach {expected} within {timeout} seconds")


class RotationCheckpoint(Checkpoint):
    def prepare_keycloak(self):
        super().prepare_keycloak()
        self.keycloak_process = self.processes[-1]

    def admin(self, path: str, method: str = "GET", data=None, expected: int = 200):
        # Both URL and credentials belong to the newly created loopback-only realm.
        body = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli", "username": "admin",
                                       "password": "synthetic-restart-admin"}).encode()
        token = json.loads(request(self.kc_url + "/realms/master/protocol/openid-connect/token", "POST", body,
                                  headers={"Content-Type": "application/x-www-form-urlencoded"}))["access_token"]
        return request(self.kc_url + "/admin/realms/trove" + path, method, data, token, expected=expected)

    def rotate(self, priority: int) -> FixtureToken:
        realm = json.loads(self.admin(""))
        require(isinstance(realm.get("id"), str), "Missing owned realm identity")
        self.admin("/components", "POST", {
            "name": "verification-rsa-" + str(priority), "providerId": "rsa-generated",
            "providerType": "org.keycloak.keys.KeyProvider", "parentId": realm["id"],
            "config": {"priority": [str(priority)], "enabled": ["true"], "active": ["true"],
                       "algorithm": ["RS256"], "keySize": ["2048"]},
        }, expected=201)
        return FixtureToken.inspect(self.token("alice@example.com"))

    def jwks(self) -> set[str]:
        value = json.loads(request(self.kc_url + "/realms/trove/protocol/openid-connect/certs"))
        require(isinstance(value, dict) and isinstance(value.get("keys"), list), "Invalid published JWKS")
        keys = [item.get("kid") for item in value["keys"] if isinstance(item, dict) and item.get("alg") == "RS256"]
        require(all(isinstance(key, str) and key for key in keys) and len(keys) == len(set(keys)), "Invalid published key identifiers")
        return set(keys)

    def exercise_rotation(self):
        backend = self.backend(1)
        original = FixtureToken.inspect(self.token("alice@example.com"))
        self.api_json("/participant/profile", original.bearer, "POST", {
            "firstName": "Synthetic", "lastName": "Participant", "gender": "preferNotToState", "dateOfBirth": "1990-01-01",
            "region": "US", "language": "en-US", "phoneNumber": "+16505550123",
        }, expected=201)
        status = probe(self.api, original)
        require(status == 200, f"Original-key fixture returned {status}, expected 200")
        provider = key_provider(json.loads(self.admin("/keys")), original.key)
        rotated = self.rotate(200)
        require(rotated.key != original.key and {original.key, rotated.key} <= self.jwks(), "Rollover did not publish both keys")
        first_delay = await_status(self.api, rotated, 200, 401, 45)
        require(probe(self.api, original) == 200, "Rollover unexpectedly rejected the retained key")
        print("PASS: new signing key accepted without backend restart; retained key still accepted", flush=True)

        # Resolve the exact provider before deleting it, only in this owned realm.
        self.admin("/components/" + provider, "DELETE", expected=204)
        current = self.rotate(300)
        require(current.key not in {original.key, rotated.key}, "Second rollover reused a key")
        published = self.jwks()
        require(original.key not in published and {rotated.key, current.key} <= published, "Retired key remains published")
        second_delay = await_status(self.api, current, 200, 401, 45)
        require(probe(self.api, original) == 401, "Successful refresh retained a removed signing key")
        require(probe(self.api, rotated) == 200, "Refresh dropped a still-published key")
        print("PASS: authoritative refresh removes retired trust and retains published keys", flush=True)

        # The development token intentionally outlives the normal five-minute key
        # cache, so a denial here cannot be explained by token expiration.
        require(current.expires_at > time.time() + 600, "Fixture token cannot isolate key-cache expiry")
        self.stop(self.keycloak_process)
        require(probe(self.api, current) == 200, "Unexpired cached trust was unexpectedly unavailable")
        print("Checking outage with the real 300-second trust lifetime; no shortened test configuration", flush=True)
        expiry_delay = await_status(self.api, current, 503, 200, 315)
        require(probe(self.api, current) == 503 and backend.poll() is None, "Expired-trust failure was not stable")
        require(current.expires_at > time.time(), "Token expired before the trust-cache assertion")
        require(self.sql("SELECT 1;") == "1", "Database unavailable during authentication-outage assertion")
        request(self.api + "/health")
        server_log = (self.evidence / "server-1.log").read_text()
        require("Signing-key verification temporarily unavailable" in server_log,
                "Missing evidence that trust refresh caused the unavailable response")
        for token in (original, rotated, current):
            require(token.bearer not in server_log, "Bearer token leaked into backend diagnostics")
        self.summary.update(passed=True, mode="real-keycloak-signing-key-rotation", signingKeyRotation={
            "newKeyAcceptedWithoutRestart": True, "retainedKeyAccepted": True, "removedKeyDeniedAfterRefresh": True,
            "unexpiredCacheSurvivesOutage": True, "expiredCacheFailsClosed": True, "unexpiredTokenAtDenial": True,
            "firstRolloverSeconds": first_delay, "secondRolloverSeconds": second_delay,
            "outageToUnavailableSeconds": expiry_delay, "cacheLifetimeSeconds": 300, "refreshCooldownSeconds": 30,
            "bearerAbsentFromServerLog": True, "keyRefreshFailureObserved": True, "databaseAndHealthRemainAvailable": True,
        })


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_stack_arguments(parser)
    args = parser.parse_args()
    os.umask(0o077)
    checkpoint = RotationCheckpoint(args)
    run_verification(checkpoint, checkpoint.exercise_rotation)
    print("PASS: real Keycloak rollover, retired-key removal and fail-closed trust expiry; owned cleanup complete", flush=True)


if __name__ == "__main__":
    main()
