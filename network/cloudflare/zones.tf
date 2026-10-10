# The public zones. Created in the dashboard long before this stack; only
# referenced here (IDs are not secret).
locals {
  zone_id = {
    com = "2e52296cc77210300b7101fc1028f6ab" # kubeletto.com
    app = "befeea828fba52cf67f332d5319e603e" # kubeletto.app
  }
}
