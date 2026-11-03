# Custom resource: generate a self-signed RSA-2048 certificate (pure Python, no dependency) and import it
# into ACM. Embedded (compressed) in template.yaml by build-template.py. Disposable demo use only.
import base64, datetime, hashlib, json, secrets, time, urllib.request
import boto3

SMALL = [p for p in range(3, 2000) if all(p % q for q in range(2, int(p ** 0.5) + 1))]


def is_prime(n):
    for p in SMALL:
        if n % p == 0:
            return n == p
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for _ in range(40):
        a = 2 + secrets.randbelow(n - 3)
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def gen_prime(bits, e):
    while True:
        n = secrets.randbits(bits) | (1 << (bits - 1)) | (1 << (bits - 2)) | 1
        if (n - 1) % e and is_prime(n):
            return n


def length(n):
    if n < 128:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([128 | len(b)]) + b


def tlv(tag, content):
    return bytes([tag]) + length(len(content)) + content


def integer(n):
    return tlv(2, n.to_bytes(n.bit_length() // 8 + 1, "big"))


def seq(*items):
    return tlv(0x30, b"".join(items))


def oid(hexstr):
    return tlv(6, bytes.fromhex(hexstr))


def pem(label, der):
    b = base64.b64encode(der).decode()
    body = "\n".join(b[i:i + 64] for i in range(0, len(b), 64))
    return "-----BEGIN %s-----\n%s\n-----END %s-----\n" % (label, body, label)


NULL = b"\x05\x00"
RSA_ALG = seq(oid("2a864886f70d010101"), NULL)
SHA256_RSA = seq(oid("2a864886f70d01010b"), NULL)


def name(cn):
    return seq(tlv(0x31, seq(oid("550403"), tlv(0x0C, cn.encode()))))


def utc(t):
    return tlv(0x17, t.strftime("%y%m%d%H%M%SZ").encode())


def make_cert(cn, days):
    e = 65537
    while True:
        p, q = gen_prime(1024, e), gen_prime(1024, e)
        if p != q:
            break
    n, phi = p * q, (p - 1) * (q - 1)
    d = pow(e, -1, phi)
    now = datetime.datetime.now(datetime.timezone.utc)
    spki = seq(RSA_ALG, tlv(3, b"\x00" + seq(integer(n), integer(e))))
    san = seq(oid("551d11"), tlv(4, seq(tlv(0x82, cn.encode()))))
    tbs = seq(tlv(0xA0, integer(2)), integer(secrets.randbits(63) + 1), SHA256_RSA, name(cn),
              seq(utc(now - datetime.timedelta(hours=1)), utc(now + datetime.timedelta(days=days))),
              name(cn), spki, tlv(0xA3, seq(san)))
    digest = seq(seq(oid("608648016503040201"), NULL), tlv(4, hashlib.sha256(tbs).digest()))
    k = (n.bit_length() + 7) // 8
    em = b"\x00\x01" + b"\xff" * (k - len(digest) - 3) + b"\x00" + digest
    sig = pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")
    cert = seq(tbs, SHA256_RSA, tlv(3, b"\x00" + sig))
    rsa_key = seq(integer(0), integer(n), integer(e), integer(d), integer(p), integer(q),
                  integer(d % (p - 1)), integer(d % (q - 1)), integer(pow(q, -1, p)))
    key = seq(integer(0), RSA_ALG, tlv(4, rsa_key))
    return pem("CERTIFICATE", cert), pem("PRIVATE KEY", key)


def respond(event, context, status, data, rid, reason=None):
    # Answers CloudFormation through the pre-signed URL. The helper module AWS documents for inline code is not
    # present in this runtime, so only the standard library is used.
    body = json.dumps({"Status": status, "Reason": reason or "See log stream " + str(getattr(context, "log_stream_name", "")),
                       "PhysicalResourceId": rid, "StackId": event["StackId"], "RequestId": event["RequestId"],
                       "LogicalResourceId": event["LogicalResourceId"], "NoEcho": False, "Data": data}).encode()
    req = urllib.request.Request(event["ResponseURL"], data=body, method="PUT", headers={"Content-Type": ""})
    urllib.request.urlopen(req, timeout=20).read()


def delete_cert(acm, arn, context=None):
    # The certificate is still attached to the listeners for a short while after they are deleted.
    for _ in range(12):
        if context and context.get_remaining_time_in_millis() < 25000:
            return False   # answer CloudFormation before the Lambda times out
        try:
            acm.delete_certificate(CertificateArn=arn)
            return True
        except Exception as ex:
            code = getattr(ex, "response", {}).get("Error", {}).get("Code", "")
            if code == "ResourceNotFoundException":
                return True
            if code != "ResourceInUseException":
                print("delete failed:", ex)
                return False
            time.sleep(10)
    return False


def handler(event, context):
    rid = event.get("PhysicalResourceId", "none")
    try:
        acm = boto3.client("acm")
        props = event["ResourceProperties"]
        if event["RequestType"] == "Create":
            crt, key = make_cert(props.get("CommonName", "pq-demo.example.internal"), int(props.get("ValidityDays", 7)))
            rid = acm.import_certificate(Certificate=crt.encode(), PrivateKey=key.encode(),
                                         Tags=[{"Key": "Name", "Value": "pq-alb-demo"}])["CertificateArn"]
        elif event["RequestType"] == "Delete" and rid.startswith("arn:"):
            if not delete_cert(acm, rid, context):
                print("Certificate %s was not deleted: remove it manually in ACM." % rid)
        respond(event, context, "SUCCESS", {"CertificateArn": rid}, rid)
    except Exception as ex:
        print("error:", ex)
        respond(event, context, "FAILED" if event["RequestType"] != "Delete" else "SUCCESS", {}, rid, str(ex)[:200])
