{ nixpkgs, system, ... }:

let
  inherit (nixpkgs) lib;
in
lib.optionalAttrs (lib.hasSuffix "-linux" system) {
  cloud-hypervisor-notify = import (nixpkgs + "/nixos/tests/make-test-python.nix")
    ({ pkgs, ... }:
      let
        inherit (import ../lib { inherit lib; }) extractOptValues extractParamValue;
        # Exercise the runner's actual notification setup without booting a VM.
        runner = import ../lib/runners/cloud-hypervisor.nix {
          inherit pkgs extractOptValues extractParamValue;
          macvtapFds = { };
          linuxTarget = "unused";
          microvmConfig = {
            preStart = "";
            socket = null;
            vsock.cid = 42;
            cloud-hypervisor.extraArgs = [ ];
            graphics.enable = false;
          };
        };
        relay = pkgs.writeShellScript "notify-relay-test" ''
          set -euo pipefail
          ${runner.preStart}
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
      in {
        name = "cloud-hypervisor-notify";
        nodes.host = {
          users.users.operator = {
            isNormalUser = true;
            uid = 1000;
            group = "operator";
            linger = true;
          };
          users.groups.operator.gid = 1000;
          environment.systemPackages = [ pkgs.python3 ];
          systemd.user.services.notify-relay-test.serviceConfig = {
            ExecStart = relay;
            Type = "notify";
            NotifyAccess = "all";
            RuntimeDirectory = "notify-relay-test";
            RuntimeDirectoryMode = "0700";
            WorkingDirectory = "%t/notify-relay-test";
            TimeoutStartSec = 10;
          };
        };
        testScript = ''
          import json
          import shlex

          def operator(script: str) -> str:
              return "su --login operator --command " + shlex.quote(
                  "export XDG_RUNTIME_DIR=/run/user/1000; " + script)

          def properties() -> dict[str, dict[str, object]]:
              path = "/org/freedesktop/systemd1/unit/notify_2drelay_2dtest_2eservice"
              return json.loads(host.succeed(operator(
                  "busctl --user --json=short call org.freedesktop.systemd1 " + path +
                  " org.freedesktop.DBus.Properties GetAll s org.freedesktop.systemd1.Service")))["data"][0]

          start_all()
          host.wait_for_unit("user@1000.service")
          manager_pid = int(host.succeed("systemctl show --value -p MainPID user@1000.service"))
          assert manager_pid > 1
          host.succeed(operator("systemctl --user start --no-block notify-relay-test.service"))
          endpoint = "/run/user/1000/notify-relay-test/notify.vsock_8888"
          host.wait_until_succeeds("test -S " + endpoint)
          main_pid = properties()["MainPID"]["data"]
          assert isinstance(main_pid, int) and main_pid > 1
          host.succeed(f"kill -STOP {manager_pid}")
          try:
              for payload, half_close in ((b"STATUS=first", True), (b"STATUS=legacy", False),
                                          (b"READY=1\nSTATUS=final", True)):
                  probe = "import socket; s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(2); "
                  probe += f"s.connect({endpoint!r}); s.sendall({payload!r}); "
                  if half_close:
                      probe += "s.shutdown(socket.SHUT_WR); "
                  probe += "assert s.recv(1) == bytes(); s.close()"
                  host.succeed(operator("python3 -c " + shlex.quote(probe)))
              # Ensure short-lived stream handlers are reaped before systemd
              # can attribute any queued datagrams. The relay parents remain.
              probe = "from pathlib import Path; "
              probe += f"parents=Path('/proc/{main_pid}/task/{main_pid}/children').read_text().split(); "
              probe += "assert parents; "
              probe += "assert all(not Path(f'/proc/{pid}/task/{pid}/children').read_text().split() for pid in parents)"
              host.wait_until_succeeds("python3 -c " + shlex.quote(probe), timeout=3)
          finally:
              host.succeed(f"kill -CONT {manager_pid}")
          host.wait_until_succeeds(operator("systemctl --user is-active --quiet notify-relay-test.service"), timeout=5)
          state = properties()
          assert state["Result"]["data"] == "success"
          assert state["StatusText"]["data"] == "final"
          assert state["MainPID"]["data"] == main_pid
          host.succeed(operator("systemctl --user stop notify-relay-test.service"))
          host.wait_until_fails("test -e /run/user/1000/notify-relay-test")
        '';
      }) {
        inherit system;
        pkgs = nixpkgs.legacyPackages.${system};
      };
}
