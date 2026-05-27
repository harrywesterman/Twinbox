def text($value):
  if $value == null then
    empty
  elif ($value | type) == "array" then
    $value | map(tostring) | join("")
  else
    $value | tostring
  end;

def dkim_value($record):
  (
    $record.value?,
    $record.values?,
    $record.target?,
    $record.targets?,
    $record.content?,
    $record.data?,
    $record.record?
  )
  | text(.)
  | select(test("v=DKIM1|p=[A-Za-z0-9+/=]{40,}"));

def dkim_name($record):
  (
    $record.name?,
    $record.dnsName?,
    $record.dns_name?,
    $record.host?,
    $record.hostname?,
    $record.qname?,
    $record.label?
  )
  | text(.)
  | select(test("(^|\\.)_domainkey(\\.|$)"));

[
  .. | objects | . as $record
  | (dkim_value($record)) as $value
  | (dkim_name($record)) as $name
  | {
      name: ($name | sub("\\.$"; "")),
      value: $value
    }
][0] // empty
