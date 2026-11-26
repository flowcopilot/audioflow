# The native participant tests use a second node. Start distribution here so
# `mix test` needs no flags; epmd ships with ERTS.
unless Node.alive?() do
  epmd = Path.join([:code.root_dir(), "erts-#{:erlang.system_info(:version)}", "bin", "epmd"])
  System.cmd(epmd, ["-daemon"])
  name = :"sfu_test_#{System.unique_integer([:positive])}@127.0.0.1"
  {:ok, _} = :net_kernel.start(name, %{name_domain: :longnames})
end

ExUnit.start()
