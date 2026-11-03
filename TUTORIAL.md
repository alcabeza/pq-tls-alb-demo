# Tutorial: see post-quantum TLS on an ALB

Duration: about 25 minutes, of which 5 minutes of waiting for the connection logs.

## Step 0 - Deploy

Follow the "Deploy" section of the README (one command, the certificate is created by the stack). Check the status:

```bash
export AWS_REGION=eu-west-3
aws cloudformation describe-stacks --region $AWS_REGION --stack-name pq-alb-demo \
  --query "Stacks[0].StackStatus" --output text
```

Wait for `CREATE_COMPLETE`.

## Step 1 - Open a session on the client

```bash
INSTANCE_ID=$(aws cloudformation describe-stack-resource --region $AWS_REGION \
  --stack-name pq-alb-demo --logical-resource-id DemoInstance \
  --query StackResourceDetail.PhysicalResourceId --output text)
aws ssm start-session --region $AWS_REGION --target $INSTANCE_ID
cd /opt/pq-alb-demo/scripts
```

If the session is refused right after deployment, wait one or two minutes (SSM agent registration).

## Step 2 - Check the installation (script 01)

```bash
bash 01-verify-install.sh
```

Expected: `INSTALLATION COMPLETE`. The OpenSSL line shows the version in use (3.5 or later).

| If you see | Action |
|---|---|
| OpenSSL < 3.5 | Read `/var/log/pq-alb-userdata.log` (build from source may have failed) |
| TCP port 443, 8443 or 9443 not reachable | Check the ALB security group and that both listeners exist |
| Setup marker missing (warning) | Setup still running: `tail -f /var/log/pq-alb-userdata.log` |

## Step 3 - Read the load balancer configuration (script 02)

```bash
bash 02-verify-alb-policy.sh
```

Expected: `ALB POLICY CONFIGURATION OK`. You see three listeners (two PQ policies, one classical) and connection
logs enabled. The difference between them is a policy name.

## Step 4 - Prove what is negotiated (script 03)

```bash
bash 03-test-negotiation.sh
```

Expected: `NEGOTIATION AS EXPECTED` (10 cases). Read it as a table:

| Client | Port 443 (PQ, TLS 1.2+1.3) | Port 9443 (PQ, TLS 1.3 only) | Port 8443 (classical) |
|---|---|---|---|
| TLS 1.3, offers `X25519MLKEM768` + `X25519` | `X25519MLKEM768` | `X25519MLKEM768` | `X25519` (silent fallback) |
| TLS 1.3, offers `X25519` only | `X25519` (**not blocked**) | `X25519` (**not blocked**) | not tested |
| TLS 1.2 | connects (classical) | **refused** | not tested |
| TLS 1.3, offers `X25519MLKEM768` only | not tested | not tested | **refused** (no shared group) |

Two lessons. A PQ policy **does not refuse** a TLS 1.3 client that lacks ML-KEM: it connects with `X25519`.
What a policy can refuse is a TLS version or cipher suite it does not offer (TLS 1.2 on port 9443). The last row
fails only because that client offers nothing else: it is a test artifact, not a real client.

By hand, for one handshake:

```bash
source /opt/pq-alb-demo/demo.env; source /opt/pq-alb-demo/openssl.env 2>/dev/null
${OPENSSL_BIN:-openssl} s_client -connect $ALB_DNS:443 -tls1_3 -groups X25519MLKEM768 </dev/null 2>&1 \
  | grep -E 'Negotiated TLS1.3 group|Cipher is'
```

## Step 5 - Read the connection logs (script 04)

Script 03 created connections. The ALB writes a log file about every 5 minutes. To avoid waiting by hand,
`bash 07-wait-then-read-logs.sh` pauses 5 minutes, then runs 04 and 06 in a row.

```bash
WAIT_MINUTES=10 bash 04-read-connection-logs.sh
```

Expected: a table of connections per listener port with the `tls_keyexchange` value, and the average TLS
handshake time recorded by the ALB. You should see different values for ports 443 and 8443. Nothing is
hard-coded: the values are whatever AWS writes.

If it says "No connection log entries yet": wait and retry; if still nothing after 15 minutes, check the
bucket policy and `02` step 3.

## Step 6 - List the clients that are still classical (script 06)

Since the load balancer cannot block them, find them:

```bash
bash 06-detect-non-pq-clients.sh
```

Expected: a table by client IP with three counts per client: **hybrid**, **classical** (handshake completed
without ML-KEM: the clients to migrate) and **no TLS** (refused handshakes and plain TCP probes, which the load
balancer logs with `-`). After step 4 this instance shows all three, because script 03 produces them on purpose.
In a real environment, the **classical** column is your migration list.

The script recognizes hybrid exchanges with `PQ_PATTERN` (default `mlkem|ml-kem|kyber`). The values AWS actually
writes are `X25519MLKEM768`, `SecP256r1MLKEM768`, `SecP384r1MLKEM1024` (hybrid) and lowercase `x25519` (classical),
so the default works; adjust it only if AWS adds new names (`PQ_PATTERN='...' bash 06-detect-non-pq-clients.sh`).

## Step 7 - Measure the cost (script 05, optional)

```bash
bash 05-benchmark-handshake.sh                       # 200 iterations per case
ITERATIONS=500 WARMUP=50 bash 05-benchmark-handshake.sh
```

Read p50 and p95 and the difference between the two rows. Expect a small difference (the hybrid key share is
larger, the computation is cheap). The first lines check that each listener negotiates what you expect, so a
misconfigured run stops instead of printing meaningless numbers.

## Step 8 - Summary

| Step | Script | Success if |
|---|---|---|
| 2 | `01` | `INSTALLATION COMPLETE` |
| 3 | `02` | `ALB POLICY CONFIGURATION OK` |
| 4 | `03` | `NEGOTIATION AS EXPECTED` |
| 5 | `04` | different key exchange values per listener |
| 6 | `06` | non-hybrid clients listed |
| 7 | `05` | two latency rows, small difference |

## Step 9 - Clean up

Leave the session (`exit`), then from your workstation:

```bash
AWS_REGION=eu-west-3 bash tools/cleanup.sh
```

## Troubleshooting

- **Both listeners show the same group**: check the policy names in `02`. A listener with a PQ name and a client
  that offers X25519 only is expected to stay classical.
- **`Negotiated TLS1.3 group` line missing**: your OpenSSL is too old; `openssl version` must be 3.5 or later.
- **Stack fails at `GeneratedCertificate`**: read the Lambda log group `/aws/lambda/<stack>-CertFunction-...` in CloudWatch Logs, or pass your own `CertificateArn`.
- **Stack in `DELETE_FAILED`**: a late log file landed in the bucket. Run `tools/cleanup.sh` again.
