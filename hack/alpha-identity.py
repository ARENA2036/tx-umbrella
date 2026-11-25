#!/usr/bin/env python3
"""Operator tool for the identity stack of charts/alpha: generated Secrets and the Vault lifecycle.

    hack/alpha-identity.py -n NAMESPACE secrets [--edc] [--execute]   create the generated Secrets (dry run by default)
    hack/alpha-identity.py -n NAMESPACE vault status                  read-only: initialized / sealed
    hack/alpha-identity.py -n NAMESPACE vault init                    once: 5 Shamir key shares, threshold 3
    hack/alpha-identity.py -n NAMESPACE vault unseal                  after every start of the Vault pod
    hack/alpha-identity.py -n NAMESPACE vault configure               once: KV v2 mounts, policies and tokens of
                                                                      issuerservice, identityhub and bdrs; BDRS aliases
    hack/alpha-identity.py -n NAMESPACE vault configure-edc           after the test participants are onboarded:
                                                                      mounts, tokens and keys of the test connectors
    hack/alpha-identity.py -n NAMESPACE vault revoke-root             after configure / configure-edc are verified

Secret and component names are the defaults of charts/alpha/values.yaml. Every changing command asks for a typed
confirmation. Secret values are generated in memory or in a private temporary directory, passed to kubectl only as
file paths and never printed. Existing Secrets and Vault entries are never overwritten. Vault is reached through
`kubectl port-forward` to the Vault server pod on 127.0.0.1 (a sealed Vault has no ready Service endpoint). The init
file (unseal keys and root token) is written with mode 0600; move the unseal keys to separate safe storage.
"""
import argparse
import base64
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

IDENTITY_SECRETS = {
    "identity-postgresql": ["postgres-password"],
    "identity-db-users": ["ISSUERSERVICE_DB_PASSWORD", "IDENTITYHUB_DB_PASSWORD", "BDRS_DB_PASSWORD"],
    "issuerservice-superuser": ["api-key"],
    "identityhub-superuser": ["api-key"],
    "bdrs-management": ["api-key"],
    "portal-bdrs": ["management-api-key"],
    "portal-identityhub": ["identityhub-api-key", "issuerservice-admin-api-key"],
}
EDC_SECRETS = {
    "edc-postgresql": ["postgres-password"],
    "edc-db-users": ["EDC_PROVIDER_DB_PASSWORD", "EDC_CONSUMER_DB_PASSWORD"],
    "edc-provider-auth": ["management-api-key", "proxy-api-key"],
    "edc-consumer-auth": ["management-api-key", "proxy-api-key"],
}
VAULT_APPS = ("issuerservice", "identityhub", "bdrs")
TOKEN_SETTINGS = {"period": "768h", "renewable": True, "no_parent": True}


class Abort(Exception):
    pass


class Kube:
    """kubectl restricted to get, port-forward and create secret."""

    def __init__(self, args):
        self.base = ["kubectl", "--request-timeout=20s", "-n", args.namespace]
        if args.kubeconfig:
            self.base[1:1] = ["--kubeconfig", args.kubeconfig]
        if args.context:
            self.base[1:1] = ["--context", args.context]
        self.namespace = args.namespace

    def run(self, *cmd):
        if cmd[0] != "get" and cmd[:2] != ("create", "secret"):
            raise Abort(f"refused: kubectl {' '.join(cmd[:2])}")
        p = subprocess.run(self.base + list(cmd), capture_output=True, text=True)
        if p.returncode != 0:
            raise Abort(f"kubectl {' '.join(cmd[:3])} failed: {p.stderr.strip().splitlines()[-1:]}")
        return p.stdout

    def secret_exists(self, name):
        return bool(self.run("get", "secret", name, "--ignore-not-found", "-o", "name").strip())

    def secret_value(self, name, key):
        raw = self.run("get", "secret", name, "-o", f"jsonpath={{.data.{key}}}")
        if not raw:
            raise Abort(f"Secret {name} has no key {key}")
        return base64.b64decode(raw).decode()

    def create_secret(self, name, values, workdir):
        args = []
        for key, value in values.items():
            path = os.path.join(workdir, f"{name}.{key}")
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
                f.write(value)
            args.append(f"--from-file={key}={path}")
        try:
            self.run("create", "secret", "generic", name, *args)
        finally:
            for a in args:
                os.remove(a.split("=", 2)[2])


def confirm(phrase):
    try:
        tty = open("/dev/tty", "r+")
    except OSError:
        raise Abort("no terminal for confirmation; nothing changed")
    with tty:
        tty.write(f'Type exactly "{phrase}": ')
        tty.flush()
        if tty.readline().strip() != phrase:
            raise Abort("confirmation did not match; nothing changed")


def random_value():
    return secrets.token_urlsafe(32)


def cmd_secrets(args, kube):
    wanted = EDC_SECRETS if args.edc else IDENTITY_SECRETS
    present = [n for n in wanted if kube.secret_exists(n)]
    for name, keys in wanted.items():
        print(f"plan  Secret {name}  keys: {', '.join(keys)}")
    if present:
        raise Abort(f"already present, nothing created: {', '.join(present)}")
    if not args.execute:
        print("DRY RUN: nothing created (add --execute).")
        return
    confirm(f"create the {'edc' if args.edc else 'identity'} secrets in {kube.namespace}")
    bdrs_key = random_value()  # one BDRS management key, read by BDRS (through Vault) and by the Portal
    with tempfile.TemporaryDirectory() as work:
        os.chmod(work, 0o700)
        for name, keys in wanted.items():
            values = {}
            for key in keys:
                if name.endswith("-superuser"):
                    # format expected by the super-user seed of IssuerService/IdentityHub: base64(<participant>).<random>
                    values[key] = base64.b64encode(b"super-user").decode() + "." + random_value()
                elif name in ("bdrs-management", "portal-bdrs"):
                    values[key] = bdrs_key
                elif name == "portal-identityhub":
                    values[key] = "pending-seed"  # replaced by the identity seed Job
                else:
                    values[key] = random_value()
            kube.create_secret(name, values, work)
            print(f"OK   created Secret {name} ({len(keys)} key(s))")


class Vault:
    def __init__(self, kube, port):
        pods = kube.run("get", "pods", "-l", "app.kubernetes.io/name=vault,component=server",
                        "-o", "jsonpath={.items[*].metadata.name}").split()
        if len(pods) != 1:
            raise Abort(f"expected exactly one Vault server pod in {kube.namespace}, found {len(pods)}")
        self.pod = pods[0]
        self.url = f"http://127.0.0.1:{port}"
        self.token = None
        self.pf = subprocess.Popen(kube.base + ["port-forward", "--address", "127.0.0.1", f"pod/{self.pod}", f"{port}:8200"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(30):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=1).close()
                break
            except OSError:
                time.sleep(1)
        else:
            self.close()
            raise Abort(f"Vault pod {self.pod} not reachable on 127.0.0.1:{port}")
        print(f"OK   port-forward to pod/{self.pod} on 127.0.0.1:{port}")

    def close(self):
        self.pf.terminate()
        self.pf.wait(timeout=10)

    def api(self, method, path, body=None, token=None):
        """-> (status, parsed JSON or None). Response bodies are never printed."""
        req = urllib.request.Request(self.url + path, method=method,
                                     data=None if body is None else json.dumps(body).encode())
        req.add_header("Content-Type", "application/json")
        if token or self.token:
            req.add_header("X-Vault-Token", token or self.token)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                data = r.read()
                return r.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            return e.code, None
        except urllib.error.URLError as e:
            raise Abort(f"Vault not reachable: {e.reason}")

    def expect(self, what, status, *codes):
        if status not in codes:
            raise Abort(f"{what} failed ({status})")

    def mount_and_policy(self, mount, rules):
        status, _ = self.api("POST", f"/v1/sys/mounts/{mount}", {"type": "kv", "options": {"version": "2"}})
        self.expect(f"mount {mount}", status, 200, 204, 400)  # 400: exists
        status, _ = self.api("PUT", f"/v1/sys/policies/acl/{mount}", {"policy": rules})
        self.expect(f"policy {mount}", status, 200, 204)
        print(f"OK   KV v2 mount and policy {mount}")

    def new_token(self, policy):
        status, data = self.api("POST", "/v1/auth/token/create-orphan",
                                {"policies": [policy], "display_name": policy, **TOKEN_SETTINGS})
        self.expect(f"token for {policy}", status, 200)
        return data["auth"]["client_token"]

    def write_once(self, mount, alias, value, token=None):
        """KV v2 create-only (cas 0); an existing alias is kept."""
        status, _ = self.api("POST", f"/v1/{mount}/data/{alias}", {"options": {"cas": 0}, "data": {"content": value}}, token)
        self.expect(f"writing {mount}/{alias}", status, 200, 400)
        print(f"OK   {mount}/{alias} {'written' if status == 200 else 'exists (not overwritten)'}")

    def read(self, mount, alias, token=None):
        status, data = self.api("GET", f"/v1/{mount}/data/{alias}", token=token)
        if status == 404:
            return None
        self.expect(f"reading {mount}/{alias}", status, 200)
        return data["data"]["data"]["content"]


def load_init(path, need_root=False):
    if not os.path.isfile(path):
        raise Abort(f"{path} not found (run `vault init` first)")
    with open(path) as f:
        d = json.load(f)
    if need_root and not d.get("root_token"):
        raise Abort(f"no root token in {path}: generate one with the unseal keys (vault operator generate-root)")
    return d


def generate_signer_pair():
    """RSA-2048 PKCS#8 key pair generated by openssl into a private temporary directory."""
    with tempfile.TemporaryDirectory() as work:
        key, pub = os.path.join(work, "signer.key"), os.path.join(work, "signer.pub")
        for cmd in (["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", key],
                    ["openssl", "pkey", "-in", key, "-pubout", "-out", pub]):
            if subprocess.run(cmd, capture_output=True).returncode != 0:
                raise Abort("key generation failed")
        with open(key) as k, open(pub) as p:
            return k.read(), p.read()


def cmd_vault(args, kube):
    init_file = os.path.expanduser(args.init_file)
    vault = Vault(kube, args.port)
    try:
        def status():
            code, s = vault.api("GET", "/v1/sys/seal-status")
            vault.expect("seal status", code, 200)
            print(f"initialized={s['initialized']} sealed={s['sealed']} progress={s['progress']}/{s['t']}")

        if args.action == "status":
            status()
        elif args.action == "init":
            if os.path.exists(init_file):
                raise Abort(f"{init_file} exists: Vault was initialised already; nothing changed")
            confirm(f"initialize the vault in {kube.namespace}")
            code, data = vault.api("PUT", "/v1/sys/init", {"secret_shares": 5, "secret_threshold": 3})
            vault.expect("init", code, 200)
            os.makedirs(os.path.dirname(init_file), mode=0o700, exist_ok=True)
            with open(os.open(init_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
                json.dump(data, f)
            print(f"OK   initialised; unseal keys and root token are in {init_file}")
        elif args.action == "unseal":
            keys = load_init(init_file)["keys_base64"]
            confirm(f"unseal the vault in {kube.namespace}")
            for i in range(3):
                code, _ = vault.api("PUT", "/v1/sys/unseal", {"key": keys[i]})
                vault.expect(f"unseal step {i + 1}", code, 200)
            status()
        elif args.action == "configure":
            vault.token = load_init(init_file, need_root=True)["root_token"]
            existing = [f"{a}-vault-token" for a in VAULT_APPS if kube.secret_exists(f"{a}-vault-token")]
            if existing:
                raise Abort(f"already present, nothing changed: {', '.join(existing)}")
            confirm(f"configure the vault in {kube.namespace}")
            with tempfile.TemporaryDirectory() as work:
                for app in VAULT_APPS:
                    vault.mount_and_policy(app, f'path "{app}/*" {{ capabilities = ["create", "read", "update", "patch", "delete", "list"] }}')
                    kube.create_secret(f"{app}-vault-token", {"token": vault.new_token(app)}, work)
                    print(f"OK   Secret {app}-vault-token (periodic 768h, policy {app})")
            # BDRS reads its database credentials and management key from Vault.
            for alias, value in (("edc.datasource.didentry.user", "bdrs"),
                                 ("edc.datasource.didentry.password", kube.secret_value("identity-db-users", "BDRS_DB_PASSWORD")),
                                 ("mgmt-api-key", kube.secret_value("bdrs-management", "api-key"))):
                vault.write_once("bdrs", alias, value)
        elif args.action == "configure-edc":
            vault.token = load_init(init_file, need_root=True)["root_token"]
            confirm(f"configure the edc test connectors in {kube.namespace}")
            with tempfile.TemporaryDirectory() as work:
                for mount, context_id in (("edc-provider", args.provider_context), ("edc-consumer", args.consumer_context)):
                    vault.mount_and_policy(mount, "\n".join((
                        f'path "{mount}/data/*" {{ capabilities = ["create", "read", "update"] }}',
                        f'path "{mount}/metadata/transfer-process-*" {{ capabilities = ["delete"] }}',
                        f'path "{mount}/metadata/edr--*" {{ capabilities = ["delete"] }}')))
                    secret = f"{mount}-vault-token"
                    if kube.secret_exists(secret):
                        token = kube.secret_value(secret, "token")
                        print(f"OK   Secret {secret} exists: token reused")
                    else:
                        token = vault.new_token(mount)
                        kube.create_secret(secret, {"token": token}, work)
                        print(f"OK   Secret {secret} (periodic 768h, policy {mount})")
                    # every alias write uses the connector's own token, exactly as the connector will
                    private, public = (vault.read(mount, "tokenSignerPrivateKey", token),
                                       vault.read(mount, "tokenSignerPublicKey", token))
                    if (private is None) != (public is None):
                        raise Abort(f"{mount} has only one half of the token-signer pair: fix by hand, nothing written")
                    if private is None:
                        private, public = generate_signer_pair()
                        vault.write_once(mount, "tokenSignerPrivateKey", private, token)
                        vault.write_once(mount, "tokenSignerPublicKey", public, token)
                    vault.write_once(mount, "tokenEncryptionAesKey", base64.b64encode(secrets.token_bytes(32)).decode(), token)
                    # the connector's STS client secret is IdentityHub's <participant>-sts-client-secret
                    sts = vault.read("identityhub", f"{context_id}-sts-client-secret")
                    if not sts:
                        raise Abort(f"identityhub/{context_id}-sts-client-secret not found: is {context_id} onboarded?")
                    vault.write_once(mount, "edc-wallet-secret", sts, token)
                    if vault.read(mount, "edc-wallet-secret", token) != sts:
                        raise Abort(f"{mount}/edc-wallet-secret differs from IdentityHub's STS client secret")
                    print(f"OK   {mount}/edc-wallet-secret matches IdentityHub (value not shown)")
        elif args.action == "revoke-root":
            data = load_init(init_file, need_root=True)
            confirm(f"revoke the vault root token in {kube.namespace}")
            code, _ = vault.api("POST", "/v1/auth/token/revoke-self", token=data["root_token"])
            vault.expect("root token revocation", code, 204)
            del data["root_token"]
            tmp = init_file + ".tmp"
            with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                json.dump(data, f)
            shutil.move(tmp, init_file)
            print(f"OK   root token revoked and removed from {init_file}")
    finally:
        vault.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("-n", "--namespace", required=True)
    ap.add_argument("--context")
    ap.add_argument("--kubeconfig")
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("secrets")
    s.add_argument("--edc", action="store_true", help="the test connector Secrets instead of the identity Secrets")
    s.add_argument("--execute", action="store_true")
    v = sub.add_parser("vault")
    v.add_argument("action", choices=["status", "init", "unseal", "configure", "configure-edc", "revoke-root"])
    v.add_argument("--init-file", default="~/.alpha-vault/vault-init.json")
    v.add_argument("--port", type=int, default=18200)
    v.add_argument("--provider-context", default="bpnl000000000fv1", help="IdentityHub participant of edc-provider")
    v.add_argument("--consumer-context", default="bpnl000000000guc", help="IdentityHub participant of edc-consumer")
    args = ap.parse_args()
    os.umask(0o077)
    kube = Kube(args)
    try:
        (cmd_secrets if args.command == "secrets" else cmd_vault)(args, kube)
    except Abort as e:
        sys.exit(f"ABORT: {e}")


if __name__ == "__main__":
    main()
