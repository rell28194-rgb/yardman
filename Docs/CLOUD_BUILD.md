# Cloud build continuation

Canonical organization: `rell28194` (`2476061786756`). Canonical project: `Yardman`. Service account: `CODEX`. Source: `https://github.com/rell28194-rgb/yardman.git`, branch `codex/arch-proof-001`.

The owner authorized use of supplied credentials. This checkout contains no credential values. This execution environment did not contain those credentials, so the API probe returned `AUTH_UNAVAILABLE` with zero requests sent. Browser sign-in also remained blocked. These are authentication blockers, not evidence of missing Unity project permissions.

The owner confirmed completing the password reset. A subsequent automated browser retry was stopped **before submission** by automatic approval review, which cited the stale incorrect-password page and account-lockout risk. No further password attempts or alternate automated credential paths were used. Resume authentication through the supported secure flow or owner-controlled sign-in; do not recover credentials from screenshots or prior prompt text.

## Prepared operations

`Tools/unity_cloud.py` uses the documented Build Automation v2 API and runtime-only service-account Basic authentication, or an explicitly supplied bearer token. It refuses redirects carrying authorization and emits sanitized metadata instead of raw project settings or credentials.

```sh
python3 Tools/unity_cloud.py probe
python3 Tools/unity_cloud.py configure
python3 Tools/unity_cloud.py build --target-id TARGET_ID --commit EXACT_40_CHARACTER_COMMIT
```

The probe resolves the canonical project unambiguously, reads build targets and Android editor availability. Successful reads do not prove write access. Server error status, code, request ID and permission detail are retained with known credential values redacted. A 403 without a named permission must remain an unspecified denied operation, not a guessed role requirement.

`configure` creates only the supplied Android target and refuses an existing same-name target for review instead of duplicating or overwriting it. It first checks the requested editor is in the cloud's available version response. The payload in `Cloud/android-proof-target.json` is prepared from the current API documentation but has not been submitted or validated against this organization's machine, entitlement and signing settings. Cloud responses may require additional configuration.

`build` requires a discovered Android target and exact source commit. This submits one build; it does not buy a plan, alter billing, publish a store release or certify a successful build. Read the returned build identifier, inspect its status/logs in Unity, and download the resulting APK only after success. Scheduled/automatic builds are disabled in the initial target payload.

The pre-export method generates the test scene and materials in Unity, selects Android ARM64/IL2CPP, minimum SDK 26, linear color, Vulkan with GLES3 fallback, and a development APK. Signing configuration must be verified in the cloud; no release keystore is embedded. iOS support and final engine selection remain pending.

References:

- https://docs.unity.com/en-us/oas-build-automation-client/2.0.0
- https://docs.unity.com/en-us/services-web-apis/service-account-auth
- https://docs.unity.com/en-us/build-automation/advanced-build-configuration/run-custom-scripts-during-the-build-process
