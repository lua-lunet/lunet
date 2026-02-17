std = "max"
max_line_length = 120

files["spec/*.lua"] = {
   std = "max+busted"
}

files["test/smoke_*.lua"] = {
   globals = { "__lunet_exit_code" }
}
