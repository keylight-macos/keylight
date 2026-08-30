BEGIN {
  forbidden[1] = "keyCode"
  forbidden[2] = "rawKeyCode"
  forbidden[3] = "charactersIgnoringModifiers"
  forbidden[4] = "horizontalPosition"
  forbidden[5] = "themeTransferString"
  forbidden[6] = "importedProfile"
  forbidden[7] = "importedTheme"
  failed = 0
  capturing = 0
}

function character_count(value, expression, copy) {
  copy = value
  return gsub(expression, "", copy)
}

function inspect_statement(term_index) {
  for (term_index = 1; term_index <= 7; term_index++) {
    if (index(statement, forbidden[term_index]) != 0) {
      printf "%s:%d: privacy-sensitive logging payload contains %s\n", \
        FILENAME, starting_line, forbidden[term_index] > "/dev/stderr"
      failed = 1
    }
  }
}

FNR == 1 {
  capturing = 0
  statement = ""
  depth = 0
}

{
  if (!capturing && $0 ~ /KeyLight(Logger|Signposts)\.[A-Za-z0-9_]+\(/) {
    capturing = 1
    starting_line = FNR
    statement = $0
    depth = character_count($0, /\(/) - character_count($0, /\)/)
  } else if (capturing) {
    statement = statement "\n" $0
    depth += character_count($0, /\(/) - character_count($0, /\)/)
  }

  if (capturing && depth <= 0) {
    inspect_statement()
    capturing = 0
    statement = ""
  }
}

END {
  exit failed
}
