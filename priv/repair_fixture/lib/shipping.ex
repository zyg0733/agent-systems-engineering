defmodule RepairFixture.Shipping do
  @moduledoc "A deliberately incorrect free-delivery boundary for the offline lab."

  def delivery_fee(subtotal) when is_integer(subtotal) and subtotal >= 0 do
    if subtotal > 100, do: 0, else: 10
  end
end
