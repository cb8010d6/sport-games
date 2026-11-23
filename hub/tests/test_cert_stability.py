"""Selected network changes extend TLS coverage without rotating the hub identity."""

import datetime as dt
import ipaddress
import ssl

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

from regina_hub import netutil


def certificate(path):
    return x509.load_pem_x509_certificate(path.read_bytes())


def private_key(path):
    return serialization.load_pem_private_key(path.read_bytes(), password=None)


def assert_valid_pair(cert_path, key_path):
    cert, key = certificate(cert_path), private_key(key_path)
    assert cert.subject == cert.issuer
    key.public_key().verify(cert.signature, cert.tbs_certificate_bytes, ec.ECDSA(cert.signature_hash_algorithm))
    assert cert.public_key().public_numbers() == key.public_key().public_numbers()
    now = dt.datetime.now(dt.UTC)
    assert cert.not_valid_before_utc < now < cert.not_valid_after_utc
    # Exercise the actual TLS consumer rather than only checking PEM parsing.
    context = netutil.ssl_context(cert_path, key_path)
    assert context.protocol == ssl.PROTOCOL_TLS_SERVER


def test_selected_ip_and_loopback_certificate_survives_restart(tmp_path, monkeypatch):
    cert_path, key_path = netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    cert = certificate(cert_path)
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert set(san.get_values_for_type(x509.IPAddress)) == {
        ipaddress.ip_address(value) for value in ("192.0.2.10", "127.0.0.1")
    }
    assert san.get_values_for_type(x509.DNSName) == ["localhost"]
    original = [(path.read_bytes(), path.stat().st_mtime_ns) for path in (cert_path, key_path)]
    # Discovery changing unrelated adapters is not a reason to replace the selected identity.
    monkeypatch.setattr(netutil, "lan_ips", lambda: ["192.0.2.10", "198.51.100.20"])
    assert netutil.ensure_cert(tmp_path, ["192.0.2.10"]) == (cert_path, key_path)
    assert [(path.read_bytes(), path.stat().st_mtime_ns) for path in (cert_path, key_path)] == original
    assert_valid_pair(cert_path, key_path)


def test_new_selected_ip_extends_san_and_keeps_private_key(tmp_path):
    cert_path, key_path = netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    original_cert = cert_path.read_bytes()
    original_key = key_path.read_bytes()
    original_key_mtime = key_path.stat().st_mtime_ns
    netutil.ensure_cert(tmp_path, ["198.51.100.20", "::1"])
    assert cert_path.read_bytes() != original_cert
    assert key_path.read_bytes() == original_key
    assert key_path.stat().st_mtime_ns == original_key_mtime
    san = certificate(cert_path).extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    assert set(san.get_values_for_type(x509.IPAddress)) == {
        ipaddress.ip_address(value) for value in ("192.0.2.10", "198.51.100.20", "127.0.0.1", "::1")
    }
    renewed = cert_path.read_bytes()
    netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    assert cert_path.read_bytes() == renewed
    assert_valid_pair(cert_path, key_path)


@pytest.mark.parametrize("expired", [True, False])
def test_expired_or_future_certificate_is_reissued_with_existing_key(tmp_path, expired):
    cert_path, key_path = netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    cert, key = certificate(cert_path), private_key(key_path)
    original_key = key_path.read_bytes()
    now = dt.datetime.now(dt.UTC)
    start = now - dt.timedelta(days=20) if expired else now + dt.timedelta(days=2)
    end = now - dt.timedelta(days=1) if expired else now + dt.timedelta(days=20)
    invalid = (x509.CertificateBuilder().subject_name(cert.subject).issuer_name(cert.issuer)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(start).not_valid_after(end)
               .add_extension(cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value, critical=False)
               .sign(key, hashes.SHA256()))
    cert_path.write_bytes(invalid.public_bytes(serialization.Encoding.PEM))
    netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    assert key_path.read_bytes() == original_key
    assert_valid_pair(cert_path, key_path)


@pytest.mark.parametrize("broken", ["certificate", "key", "mismatch"])
def test_corrupt_or_mismatched_pair_recovers_to_usable_tls(tmp_path, broken):
    cert_path, key_path = netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    original_key = key_path.read_bytes()
    if broken == "certificate":
        cert_path.write_bytes(b"not a certificate")
    elif broken == "key":
        key_path.write_bytes(b"not a key")
    else:
        other_key = ec.generate_private_key(ec.SECP256R1())
        replacement = other_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        key_path.write_bytes(replacement)
    netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    if broken == "certificate":
        assert key_path.read_bytes() == original_key
    elif broken == "mismatch":
        assert key_path.read_bytes() == replacement
    assert_valid_pair(cert_path, key_path)


def test_failed_certificate_replacement_keeps_previous_pair(tmp_path, monkeypatch):
    cert_path, key_path = netutil.ensure_cert(tmp_path, ["192.0.2.10"])
    original = (cert_path.read_bytes(), key_path.read_bytes())

    def failed_replace(_self, _target):
        raise OSError("fixture replacement denied")

    monkeypatch.setattr(type(cert_path), "replace", failed_replace)
    with pytest.raises(OSError, match="fixture replacement denied"):
        netutil.ensure_cert(tmp_path, ["198.51.100.20"])
    assert (cert_path.read_bytes(), key_path.read_bytes()) == original
    assert not list(tmp_path.glob(".pem-*"))
    assert_valid_pair(cert_path, key_path)
