PORT=$1
ss -ltn "( sport = :$PORT )"
# no output => free
