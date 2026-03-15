# ex_dna standalone configuration for `mix ex_dna`
# See also: .credo.exs for the Credo-integrated ex_dna check
%{
  min_mass: 80,
  excluded_macros: [:@, :schema, :pipe_through, :plug],
  paths: ["apps/", "config/"]
}
