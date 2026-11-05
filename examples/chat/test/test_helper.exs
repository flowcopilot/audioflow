ExUnit.start()

# Exercise downloads without compiling native engines or starting models.
unless Code.ensure_loaded?(Chat.HF) do
  Code.require_file("../native/hf.ex", __DIR__)
end
