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

def structured_dkim_record($record):
  (dkim_value($record)) as $value
  | (dkim_name($record)) as $name
  | {
      name: ($name | sub("\\.$"; "")),
      value: $value
    };

def bind_dkim_line($record):
  (
    $record.dns_dkim?,
    $record.dnsDkim?,
    $record.dkim_dns?,
    $record.dkimDns?
  )
  | text(.)
  | select(test("(^|\\.)_domainkey\\."; "i"))
  | select(test("v=DKIM1|p=[A-Za-z0-9+/=]{40,}"; "i"));

def bind_dkim_name($line):
  $line
  | capture("^\\s*(?<name>\\S+)").name
  | sub("\\.$"; "");

def bind_dkim_value($line):
  [
    $line
    | scan("\"([^\"]*)\"")
    | .[0]
  ]
  | join("")
  | select(test("v=DKIM1|p=[A-Za-z0-9+/=]{40,}"; "i"));

def bind_dkim_record($record):
  (bind_dkim_line($record)) as $line
  | {
      name: bind_dkim_name($line),
      value: bind_dkim_value($line)
    };

[
  .. | objects | . as $record
  | (
      structured_dkim_record($record),
      bind_dkim_record($record)
    )
][0] // empty
