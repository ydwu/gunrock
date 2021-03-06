#!/bin/sh

# get all execution files in ./bin
files=(./bin/*)
# split file names into arr
arr=$(echo $files | tr " " "\n")
max_ver_num="$"
exe_file=${arr[0]}
# iterate over all file names to get the largest version number
for x in $arr
do
    output=$(grep -o "[0-9]\.[0-9]" <<<"$x")
    if [ "$output" \> "$max_ver_num" ]; then
        exe_file=$x
    fi
done

# put OS and Device type here
SUFFIX="ubuntu12.04.k40c"

mkdir -p eval/$SUFFIX

for i in test_bc
do
    echo $exe_file market ../../dataset/small/$i.mtx
    $exe_file market ../../dataset/small/$i.mtx > eval/$SUFFIX/$i.$SUFFIX.txt
    sleep 1
done
