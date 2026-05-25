#!/usr/bin/env python3
"""Small UDP-to-TCP DNS proxy for forwarding NetBird DNS to AdGuard."""

import argparse
import socket
import struct
import sys
import threading


def forward_query(query: bytes, upstream_host: str, upstream_port: int, timeout: float) -> bytes:
    framed_query = struct.pack("!H", len(query)) + query
    with socket.create_connection((upstream_host, upstream_port), timeout=timeout) as upstream:
        upstream.settimeout(timeout)
        upstream.sendall(framed_query)
        length_prefix = upstream.recv(2)
        if len(length_prefix) != 2:
            raise OSError("upstream returned an incomplete DNS length prefix")
        response_length = struct.unpack("!H", length_prefix)[0]
        chunks = []
        remaining = response_length
        while remaining > 0:
            chunk = upstream.recv(remaining)
            if not chunk:
                raise OSError("upstream closed before sending the full DNS response")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


def handle_query(
    server: socket.socket,
    query: bytes,
    client_address: tuple[str, int],
    upstream_host: str,
    upstream_port: int,
    timeout: float,
) -> None:
    try:
        response = forward_query(query, upstream_host, upstream_port, timeout)
        server.sendto(response, client_address)
    except Exception as exc:
        print(
            f"dns-proxy: failed query from {client_address[0]}:{client_address[1]}: {exc}",
            file=sys.stderr,
        )


def serve_udp(
    listen_host: str,
    listen_port: int,
    upstream_host: str,
    upstream_port: int,
    timeout: float,
) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((listen_host, listen_port))
        print(
            f"dns-proxy: listening for UDP on {listen_host}:{listen_port}, "
            f"forwarding to tcp://{upstream_host}:{upstream_port}",
            flush=True,
        )
        while True:
            query, client_address = server.recvfrom(4096)
            thread = threading.Thread(
                target=handle_query,
                args=(server, query, client_address, upstream_host, upstream_port, timeout),
                daemon=True,
            )
            thread.start()


def read_exact(sock: socket.socket, length: int) -> bytes:
    chunks = []
    remaining = length
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise OSError("client closed before sending the full DNS query")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def handle_tcp_client(
    client: socket.socket,
    client_address: tuple[str, int],
    upstream_host: str,
    upstream_port: int,
    timeout: float,
) -> None:
    try:
        with client:
            client.settimeout(timeout)
            length_prefix = read_exact(client, 2)
            query_length = struct.unpack("!H", length_prefix)[0]
            query = read_exact(client, query_length)
            response = forward_query(query, upstream_host, upstream_port, timeout)
            client.sendall(struct.pack("!H", len(response)) + response)
    except Exception as exc:
        print(
            f"dns-proxy: failed TCP query from {client_address[0]}:{client_address[1]}: {exc}",
            file=sys.stderr,
        )


def serve_tcp(
    listen_host: str,
    listen_port: int,
    upstream_host: str,
    upstream_port: int,
    timeout: float,
) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((listen_host, listen_port))
        server.listen(50)
        print(
            f"dns-proxy: listening for TCP on {listen_host}:{listen_port}, "
            f"forwarding to tcp://{upstream_host}:{upstream_port}",
            flush=True,
        )
        while True:
            client, client_address = server.accept()
            thread = threading.Thread(
                target=handle_tcp_client,
                args=(client, client_address, upstream_host, upstream_port, timeout),
                daemon=True,
            )
            thread.start()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Forward UDP and TCP DNS queries to a TCP DNS upstream."
    )
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", type=int, default=5354)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, default=1053)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()

    udp_thread = threading.Thread(
        target=serve_udp,
        args=(
            args.listen_host,
            args.listen_port,
            args.upstream_host,
            args.upstream_port,
            args.timeout,
        ),
        daemon=True,
    )
    udp_thread.start()
    serve_tcp(
        args.listen_host, args.listen_port, args.upstream_host, args.upstream_port, args.timeout
    )


if __name__ == "__main__":
    main()
