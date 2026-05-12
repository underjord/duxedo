[
  # Adbc.Result's type spec declares `data: [Adbc.Column.t()]`, but at runtime
  # the field holds a list of batches (`[[Adbc.Column.t()]]`). The patterns
  # in list_metrics/1 and series/2 unpack the runtime shape correctly.
  {"lib/duxedo/query.ex", :pattern_match}
]
