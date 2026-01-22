import ./src/debug

import pkg/colors

debug:
  echo "Starting example"
  
  var x = 10
  let y = 20
  
  x = x + y
  
  if x > 15:
    echo "x is large"
    x = x * 2
  else:
    echo "x is small"
  
  for i in 1..3:
    echo "Loop iteration: ", i
    if i == 2:
      echo "Found 2!"
  
  proc testProc(val: int): int =
    echo "In testProc with ", val
    result = val * 2
  
  let result = testProc(5)
  echo "Result: ", result
  
  try:
    echo "About to divide"
    let z = 100 div x
    echo "Division successful: ", z
  except:
    echo "Error occurred!"
  
  echo "Done!"