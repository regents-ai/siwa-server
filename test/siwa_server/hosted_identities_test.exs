defmodule SiwaServer.HostedIdentitiesTest do
  use SiwaServer.DataCase, async: false

  import ExUnit.CaptureLog

  alias SiwaKeyring.HostedIdentity
  alias SiwaServer.HostedIdentities

  # Every hosted connection must keep its own key, and so its address, when the
  # keys move off the volume.
  @tag :tmp_dir
  test "the keys on the volume move into the database unchanged and keep their addresses",
       %{tmp_dir: dir} do
    previous_path = Application.get_env(:siwa_keyring, :path)
    previous_level = Logger.level()
    base = Path.join(dir, "keystore.bin")
    Application.put_env(:siwa_keyring, :path, base)
    Logger.configure(level: :info)

    on_exit(fn ->
      Application.put_env(:siwa_keyring, :path, previous_path)
      Logger.configure(level: previous_level)
    end)

    hosted = base <> ".hosted"
    File.mkdir_p!(hosted)
    password = Application.fetch_env!(:siwa_keyring, :password)

    addresses =
      for n <- 1..2, into: %{} do
        identity = :crypto.hash(:sha256, "#{n}") |> Base.encode16(case: :lower)
        {:ok, encrypted} = HostedIdentity.new(password)
        File.write!(Path.join(hosted, identity <> ".bin"), encrypted)
        {:ok, signer} = HostedIdentity.signer(encrypted, password)
        {identity, Siwa.RemoteSigner.get_address(signer)}
      end

    File.write!(Path.join(hosted, "unfinished.bin.tmp-1"), "partial")

    log = capture_log(fn -> assert HostedIdentities.copy_from_volume() == :ignore end)
    assert log =~ "hosted keys on the volume: 2, copied now: 2, the same in the database: 2"

    for {identity, {:ok, address}} <- addresses do
      assert HostedIdentities.ensure(identity) == {:ok, %{address: address}}
    end

    log = capture_log(fn -> HostedIdentities.copy_from_volume() end)
    assert log =~ "hosted keys on the volume: 2, copied now: 0, the same in the database: 2"
  end
end
