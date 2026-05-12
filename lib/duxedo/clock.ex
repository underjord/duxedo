defmodule Duxedo.Clock do
  @moduledoc """
  Behaviour for checking if the system clock is synchronized.

  On Nerves devices the clock may not be set at boot. Providing a clock
  implementation lets Duxedo adjust timestamps once the clock syncs.

  For Nerves devices, NervesTime can be used directly:

      {Duxedo, clock: NervesTime}

  If no clock is provided, timestamps are assumed correct from the start.
  """

  @callback synchronized?() :: boolean()
end
