ExUnit.start()

defmodule RepairFixture.ShippingTest do
  use ExUnit.Case, async: true

  test "a zero subtotal pays delivery" do
    assert RepairFixture.Shipping.delivery_fee(0) == 10
  end

  test "a subtotal below the threshold pays delivery" do
    assert RepairFixture.Shipping.delivery_fee(99) == 10
  end

  test "the threshold qualifies for free delivery" do
    assert RepairFixture.Shipping.delivery_fee(100) == 0
  end

  test "a subtotal above the threshold qualifies for free delivery" do
    assert RepairFixture.Shipping.delivery_fee(101) == 0
  end
end
