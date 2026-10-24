exclude =
  if Application.get_env(:agent_systems_lab, :database_enabled, true),
    do: [],
    else: [:database]

exclude = if :os.type() == {:unix, :darwin}, do: exclude, else: [:seatbelt | exclude]

ExUnit.start(exclude: exclude)
