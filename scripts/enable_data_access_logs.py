#!/usr/bin/env python3
"""
enable_data_access_logs.py -- turn on GCP Data Access audit logs for defendA.

Run ONCE per organization (or project), by a human who holds Organization
Administrator. Not by CI. Not by terraform.

WHY THIS IS A SCRIPT AND NOT TERRAFORM
--------------------------------------
auditConfigs live inside the org's IAM policy, so changing them requires
resourcemanager.organizations.setIamPolicy -- effectively org-admin. Three
reasons that does not belong in the deploy pipeline:

  1. The deployer SA runs `terraform apply -auto-approve` from a GitHub Actions
     runner. Org setIamPolicy there means anyone who can land a commit, compromise
     a third-party Action, or poison a workflow dependency can own the org.

  2. Control over audit logging IS the ability to disable the telemetry defendA
     runs on -- literally an attack technique (stratus
     gcp.defense-evasion.disable-audit-logs). Handing it to a push-triggered
     pipeline is self-defeating for a security platform.

  3. terraform's google_*_iam_audit_config is AUTHORITATIVE per service. A state
     loss or a destroy could REMOVE audit logging org-wide. IaC should not hold a
     live switch that blinds the SIEM.

Data Access logging is a PREREQUISITE the operator enables once -- like enabling
the Workspace Admin API for that collector. Drift is caught by DETECTION
(defenda_hunting.feed_coverage + a tripwire on auditConfig changes), not by state.

WHY NOT JUST gcloud
-------------------
There is no `gcloud` command for audit configs. The manual path is
get-iam-policy -> hand-edit YAML -> set-iam-policy, which is a read-modify-write
over the ENTIRE org IAM policy. Fumble it and you clobber every role binding in
the org -- a far worse outage than the one you were preventing.

This script does that read-modify-write carefully:
  * merges auditConfigs only, never replacing the list wholesale
  * NEVER removes an existing service's config or an existing exemption
  * passes the etag back (optimistic concurrency -- fails rather than racing)
  * hard-asserts `bindings` are byte-identical before/after
  * dry-run by default; --apply is an explicit choice

THE LOG TYPES ARE COUNTERINTUITIVE -- read before editing SERVICES
------------------------------------------------------------------
  * iam.googleapis.com has NO DATA_READ methods at all. A DATA_READ-only config
    on it applies cleanly and captures nothing.
  * GenerateAccessToken -- service-account impersonation, the highest-value cloud
    lateral-movement signal there is -- is ADMIN_READ, not DATA_READ.
  * iamcredentials.googleapis.com CANNOT be configured independently. It rides on
    iam.googleapis.com; naming it separately silently no-ops.

So ADMIN_READ on iam.googleapis.com is the line that actually buys impersonation
visibility, and it is exactly the line a reasonable person would omit.

  bigquery.googleapis.com is deliberately absent: its Data Access logs are always
  on and cannot be disabled.

USAGE
-----
    # see what would change (default -- touches nothing)
    python scripts/enable_data_access_logs.py --org-id 123456789012

    # commit it
    python scripts/enable_data_access_logs.py --org-id 123456789012 --apply

    # single project instead of the whole org (no org-admin needed)
    python scripts/enable_data_access_logs.py --project-id my-proj --apply

    # verify only -- exits non-zero if config has drifted. Safe for a cron/CI check.
    python scripts/enable_data_access_logs.py --org-id 123456789012 --check
"""

from __future__ import annotations

import argparse
import copy
import json
import sys

try:
    import google.auth
    from google.auth.transport.requests import AuthorizedSession
except ImportError:
    sys.exit("pip install google-auth requests")


CRM = "https://cloudresourcemanager.googleapis.com/v3"

# service -> log types. See the counterintuitive-log-types note above.
SERVICES: dict[str, list[str]] = {
    # ADMIN_READ is the load-bearing one: GenerateAccessToken (impersonation),
    # TestIamPermissions, GetIamPolicy, ListServiceAccountKeys. Also implicitly
    # enables iamcredentials.googleapis.com, which cannot be set on its own.
    # DATA_READ is included for completeness; IAM has no DATA_READ methods today.
    "iam.googleapis.com": ["ADMIN_READ", "DATA_READ"],
    # DATA_READ  = AccessSecretVersion (the actual secret read)
    # ADMIN_READ = GetSecret / ListSecrets (enumeration -- the recon step)
    "secretmanager.googleapis.com": ["ADMIN_READ", "DATA_READ"],
    # DATA_READ = one entry per GCS object read. The highest-volume of the three
    # by a wide margin. Drop to ADMIN_READ only if volume ever becomes a problem.
    "storage.googleapis.com": ["ADMIN_READ", "DATA_READ"],
}


def _session() -> AuthorizedSession:
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    return AuthorizedSession(creds)


def get_policy(sess: AuthorizedSession, resource: str) -> dict:
    r = sess.post(
        f"{CRM}/{resource}:getIamPolicy",
        json={"options": {"requestedPolicyVersion": 3}},
    )
    if r.status_code == 403:
        sys.exit(
            f"403 reading the IAM policy for {resource}.\n\n"
            "You need resourcemanager.organizations.getIamPolicy / setIamPolicy --\n"
            "in practice roles/resourcemanager.organizationAdmin. This is expected to\n"
            "be run by a HUMAN with org-admin, once. If you are seeing this from CI,\n"
            "that is the script working as intended: do not grant the deployer SA\n"
            "org-level setIamPolicy. See the module docstring."
        )
    r.raise_for_status()
    return r.json()


def merge_audit_configs(policy: dict) -> tuple[dict, list[str]]:
    """Additive merge. Returns (new_policy, human-readable changes).

    Never removes a service, a logType, or an exempted member that is already
    there. Someone else's audit config is not ours to delete, and an exemption we
    did not create may be load-bearing for a bill somewhere.
    """
    new = copy.deepcopy(policy)
    existing = {c["service"]: c for c in new.get("auditConfigs", [])}
    changes: list[str] = []

    for service, log_types in SERVICES.items():
        cfg = existing.get(service)

        if cfg is None:
            new.setdefault("auditConfigs", []).append(
                {
                    "service": service,
                    "auditLogConfigs": [{"logType": lt} for lt in log_types],
                }
            )
            changes.append(f"+ {service}: enable {', '.join(log_types)}")
            continue

        have = {c["logType"] for c in cfg.get("auditLogConfigs", [])}
        for lt in log_types:
            if lt not in have:
                cfg.setdefault("auditLogConfigs", []).append({"logType": lt})
                changes.append(f"+ {service}: add {lt}")

    return new, changes


def show_exemptions(policy: dict) -> None:
    """Exemptions are blind spots. Surface any that exist -- ours or not."""
    found = []
    for cfg in policy.get("auditConfigs", []):
        for lc in cfg.get("auditLogConfigs", []):
            for m in lc.get("exemptedMembers", []) or []:
                found.append(f"{cfg['service']} / {lc['logType']}: {m}")

    if found:
        print("\n  ! EXISTING AUDIT EXEMPTIONS (these principals generate NO logs):")
        for f in found:
            print(f"      {f}")
        print(
            "    Each one is a deliberate blind spot. An attacker who compromises an\n"
            "    exempted principal is invisible for that service. Confirm each is\n"
            "    intentional. Note org/folder exemptions CANNOT be removed by a child\n"
            "    project -- only added to."
        )


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    target = p.add_mutually_exclusive_group(required=True)
    target.add_argument("--org-id", help="Organization ID (inherits to all projects)")
    target.add_argument("--project-id", help="Single project (no inheritance)")
    p.add_argument("--apply", action="store_true", help="Actually write the change")
    p.add_argument(
        "--check",
        action="store_true",
        help="Verify only; exit 1 if config has drifted. Safe for cron/CI.",
    )
    args = p.parse_args()

    resource = (
        f"organizations/{args.org_id}" if args.org_id else f"projects/{args.project_id}"
    )

    sess = _session()
    policy = get_policy(sess, resource)
    new_policy, changes = merge_audit_configs(policy)

    print(f"\ndefendA -- Data Access audit logs on {resource}\n")

    if not changes:
        print("  Already configured. Nothing to do.")
        show_exemptions(policy)
        return 0

    print("  Changes:")
    for c in changes:
        print(f"    {c}")
    show_exemptions(policy)

    if args.check:
        print(
            "\n  DRIFT: Data Access logging is not fully enabled.\n"
            "  Impersonation and secret-access hunts will return empty -- which looks\n"
            "  exactly like a quiet environment. Re-run with --apply."
        )
        return 1

    if not args.apply:
        print("\n  Dry run. Nothing written. Re-run with --apply to commit.")
        return 0

    # --- The dangerous part, with the guardrails on ---------------------------
    # setIamPolicy replaces the WHOLE policy. If bindings were mangled in memory
    # we would silently wipe every role grant in the org. Refuse to be the reason
    # that happens.
    if new_policy.get("bindings") != policy.get("bindings"):
        sys.exit(
            "ABORT: role bindings differ between the fetched and computed policy.\n"
            "This script must only ever touch auditConfigs. Refusing to write."
        )

    # etag = optimistic concurrency. If someone else edited the policy since our
    # read, fail loudly instead of clobbering their change.
    if not new_policy.get("etag"):
        sys.exit("ABORT: policy has no etag; refusing to write blind.")

    r = sess.post(f"{CRM}/{resource}:setIamPolicy", json={"policy": new_policy})
    if r.status_code == 409:
        sys.exit("ABORT: etag conflict -- the policy changed under us. Re-run.")
    if r.status_code == 403:
        sys.exit("403 writing the policy. You need org-admin. See the docstring.")
    r.raise_for_status()

    print("\n  Applied.")
    print(
        "\n  Logs take a few minutes to start flowing. Verify with the hunting schema:\n"
        "    SELECT * FROM `PROJECT.defenda_hunting.feed_coverage`\n"
        "    WHERE audit_log_type = 'data_access';\n\n"
        "  Until that returns rows, every credential-access hunt is structurally\n"
        "  blind, and an empty hunt result means nothing."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
