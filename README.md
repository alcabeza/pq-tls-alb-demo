# Post-quantum TLS on Application Load Balancer: disposable demo

An internal ALB with **three HTTPS listeners** and a test client, to see for yourself what a PQ security
policy does, and what it cannot do.

| Listener | Security policy (default) | What it shows |
|---|---|---|
| 443 | `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` | Hybrid `X25519MLKEM768` for PQ-capable clients, classical for the others |
| 9443 | `ELBSecurityPolicy-TLS13-1-3-PQ-2025-09` | TLS 1.3 only: **TLS 1.2 clients are refused**, X25519-only TLS 1.3 clients still get in |
| 8443 | `ELBSecurityPolicy-TLS13-1-2-Res-2021-06` | Control: no ML-KEM, silent classical fallback |

## The point: a PQ policy does not block classical clients

According to the AWS documentation, ALB PQ policies support both classical and ML-KEM key exchange "for
compatibility", and no policy requires post-quantum. A security policy can refuse a **TLS version or cipher
suite** (a TLS 1.2 client on the TLS 1.3 only listener), but it cannot refuse a TLS 1.3 client that simply does
not offer ML-KEM: that client connects with `X25519`, silently.

So the demo has two parts:

1. **Prove the limit** (script 03): what is refused and what is not, case by case.
2. **Detect instead of block** (scripts 04 and 06): the connection logs record `tls_keyexchange` for every
   connection, so you can list the clients that are still classical and migrate them before tightening anything.

Console-created listeners get a PQ policy by default, but listeners created with the CLI, CloudFormation or CDK
keep `ELBSecurityPolicy-2016-08` (no ML-KEM) unless you pick a PQ policy yourself. Nothing fails: the connection
just stays classical.

## What is deployed

- VPC, two subnets, internet gateway (the client needs it to install packages).
- A self-signed certificate, generated and imported into ACM by a Lambda custom resource (unless you pass your own).
- **Internal** ALB (not reachable from the internet), three listeners returning a fixed response (no targets).
- S3 bucket for connection logs (SSE-S3, public access blocked, 3-day expiration) and its bucket policy.
- EC2 test client (Amazon Linux 2023, IMDSv2, SSM Session Manager, no inbound port) with OpenSSL 3.5+. The
  system OpenSSL is used if recent enough, otherwise 3.5.9 is built from source (a few minutes).
- Nine script files embedded in the template (nothing to copy).

## Deploy

Prerequisites: AWS CLI v2 and the Session Manager plugin. Nothing else: the stack also creates its own
certificate.

```bash
export AWS_REGION=eu-west-3
aws cloudformation deploy --region $AWS_REGION --stack-name pq-alb-demo \
  --template-file template.yaml --capabilities CAPABILITY_IAM
```

The stack reaches `CREATE_COMPLETE` once the client is ready (about 5 minutes, up to 15 if OpenSSL is built).
`template.yaml` is about 29 KB, under the 51,200-byte limit for direct upload.

**Certificate.** An HTTPS listener needs one, and a public ACM certificate needs a domain name. By default a small
Lambda-backed custom resource generates a **self-signed RSA-2048 certificate** (7 days, pure Python, source in
`tools/cert_lambda.py`), imports it into ACM, and deletes it with the stack. The demo client does not validate the
chain, because the subject here is the key exchange, not the certificate. To use your own certificate instead,
pass `--parameter-overrides CertificateArn=arn:aws:acm:...` (`tools/create-cert.sh` imports a self-signed one from
your workstation if you prefer that route).

Then follow [TUTORIAL.md](TUTORIAL.md).

## Scripts (on the instance, `/opt/pq-alb-demo/scripts`)

| Script | Purpose | Success message |
|---|---|---|
| `01-verify-install.sh` | Config, OpenSSL >= 3.5, credentials, network path | `INSTALLATION COMPLETE` |
| `02-verify-alb-policy.sh` | Listener policies, connection log attributes | `ALB POLICY CONFIGURATION OK` |
| `03-test-negotiation.sh` | Ten handshakes: what a policy blocks (TLS 1.2 on 9443) and what it does not (X25519-only) | `NEGOTIATION AS EXPECTED` |
| `04-read-connection-logs.sh` | Reads S3 logs, summarizes `tls_keyexchange` per listener | table + comparison |
| `06-detect-non-pq-clients.sh` | Per client IP: hybrid, classical (completed without ML-KEM), no TLS (refused or probe) | table + counts |
| `07-wait-then-read-logs.sh` | Waits ~5 minutes for the next log delivery, then runs 04 and 06 | both reports |
| `05-benchmark-handshake.sh` | Classical vs hybrid new-connection time | table with p50/p95/p99 |

## Clean up

```bash
AWS_REGION=eu-west-3 bash tools/cleanup.sh
```

The script empties the bucket and deletes the stack (the generated certificate goes with it). If you supplied your
own `CertificateArn`, it stays in ACM. An ALB can deliver one last log
file after the bucket is emptied: if the stack ends in `DELETE_FAILED`, run the script again.

## Cost

A few cents per hour (ALB hourly charge and LCUs, `t3.small`). Delete the stack when you are done.

## Limits and honest notes

- Handshake timings from `05` include `openssl s_client` start-up. Only the **difference** between the two
  cases is meaningful, and it is small. Absolute values are not pure handshake times.
- **Observed `tls_keyexchange` values** (real deployment, eu-west-3, November 2026): `X25519MLKEM768`,
  `SecP256r1MLKEM768`, `SecP384r1MLKEM1024` for hybrid exchanges, lowercase `x25519` for classical ones (also
  for TLS 1.2), and `-` when no TLS session was established. A refused handshake (TLS 1.2 client on the TLS 1.3
  only listener, no shared group) and a plain TCP probe are both logged with `-` for cipher, key exchange and
  handshake time; the protocol column of a refused handshake should not be over-interpreted. AWS does not
  document this as a closed list, so script `06` matches on a pattern instead of hard-coding names.
- Connection logs arrive roughly every 5 minutes.
- The certificate Lambda is a demo convenience: its key is generated inside Lambda with the Python `secrets` module and never leaves ACM. Do not reuse the approach for real certificates. If the stack deletion cannot remove the certificate (still attached for a moment), the function retries for about 2 minutes, then leaves it in ACM and logs it.
- The PQ policy only protects the **client to ALB** hop. The ALB to target hop uses its own backend policy
  (`ELBSecurityPolicy-TLS13-1-0-PQ-2025-09` for PQ).
- The detection in `06` recognizes a hybrid exchange by pattern (`PQ_PATTERN`, default `mlkem|ml-kem|kyber`). Check it against the values `04` prints. To really **block** non-PQ clients you would need a TLS-terminating component you control in front of the ALB: not covered here.
- Policy names and PQ groups reflect the AWS documentation at the time of writing. Check the current list with
  `aws elbv2 describe-ssl-policies`.
- Hybrid key exchange protects the **confidentiality** of recorded traffic (harvest now, decrypt later). It does
  not change the certificate signature, which is still classical.
- Template not linted or deployed by the author's tooling (no cfn-lint or AWS access where it was built); run
  `cfn-lint template.yaml` before your first deployment. Scripts (including the refusal cases) were tested against simulated `openssl` and
  `aws` commands.

## Rebuild the template

After editing a script: `python3 build-template.py` (embeds `instance-scripts/*.sh` into `tools/template.src.yaml`).

## Licence

Use at your own risk, for learning purposes.
