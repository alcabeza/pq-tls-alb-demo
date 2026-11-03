#!/usr/bin/env python3
"""Build template.yaml: embeds instance-scripts/*.sh into tools/template.src.yaml as base64 tar.gz.
Usage: python3 build-template.py
CloudFormation limits: 51,200 bytes for a template passed directly (1 MB via S3)."""
import base64, gzip, io, pathlib, sys, tarfile

root = pathlib.Path(__file__).resolve().parent
src = (root / "tools" / "template.src.yaml").read_text(encoding="utf-8")
scripts = sorted((root / "instance-scripts").glob("*.sh"))
if not scripts:
    sys.exit("no scripts found in instance-scripts/")

buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as tar:        # tar first, gzip with fixed mtime = reproducible output
    for p in scripts:
        data = p.read_bytes().replace(b"\r\n", b"\n")
        ti = tarfile.TarInfo(p.name)
        ti.size, ti.mode, ti.mtime, ti.uname, ti.gname = len(data), 0o755, 0, "root", "root"
        tar.addfile(ti, io.BytesIO(data))
gz = io.BytesIO()
with gzip.GzipFile(fileobj=gz, mode="wb", mtime=0) as g:
    g.write(buf.getvalue())
b64 = base64.b64encode(gz.getvalue()).decode()
lines = "\n".join(" " * 16 + b64[i:i + 76] for i in range(0, len(b64), 76))

# --- Lambda for the self-signed certificate: inline code is limited to 4,096 characters, so the source
# (tools/cert_lambda.py) is shipped compressed and decoded at start-up by a tiny stub.
import zlib
lam = zlib.compress((root / "tools" / "cert_lambda.py").read_bytes().replace(b"\r\n", b"\n"), 9)
stub = ("import base64, zlib\n"
        "exec(zlib.decompress(base64.b64decode('" + base64.b64encode(lam).decode() + "')).decode())\n")
if len(stub) > 4096:
    sys.exit(f"Lambda inline code is {len(stub)} chars, limit is 4096")
print(f"certificate Lambda: {len(stub)} / 4096 characters inline")
src = src.replace("__CERT_LAMBDA_ZIPFILE__", "\n".join(" " * 10 + l for l in stub.splitlines()))

if "__SCRIPTS_B64__" not in src:
    sys.exit("placeholder __SCRIPTS_B64__ missing in template.src.yaml")
out = src.replace("__SCRIPTS_B64__", lines)
(root / "template.yaml").write_text(out, encoding="utf-8")
size = len(out.encode())
print(f"template.yaml: {size} bytes ({size * 100 // 51200}% of the 51,200-byte direct-upload limit), {len(scripts)} scripts embedded")
if size > 51200:
    print("WARNING: too large for direct upload, use --template-url or aws cloudformation package")
