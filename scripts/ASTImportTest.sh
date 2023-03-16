#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# vim:ts=4:et
# This file is part of solidity.
#
# solidity is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# solidity is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with solidity.  If not, see <http://www.gnu.org/licenses/>
#
# (c) solidity contributors.
# ------------------------------------------------------------------------------
# Bash script to test the import/exports.
#
# ast import/export tests:
#   - first exporting a .sol file to JSON, then loading it into the compiler
#     and exporting it again. The second JSON should be identical to the first.
#
# evm-assembly import/export tests:
#   - first a .sol file will be exported to a combined json file, containing outputs
#     for "asm" "bin" "bin-runtime" "opcodes" "srcmap" and "srcmap-runtime" (expected output).
#     The "asm" output will then be used as import, where its output "bin" "bin-runtime"
#     "opcodes" "srcmap" "srcmap-runtime" (obtained output) will be compared with the expected output.
#     The expected output needs to be identical with the obtained output.
#
#     Additionally to this, the direct import/export is tested by importing an
#     evm-assembly json with --import-asm-json and directly exporting it again with
#     --asm-json using the same solc invocation. The original asm json file used for the
#     import and the resulting exported asm json file need to be identical.

set -euo pipefail

READLINK=readlink
if [[ "$OSTYPE" == "darwin"* ]]; then
    READLINK=greadlink
fi
REPO_ROOT=$(${READLINK} -f "$(dirname "$0")"/..)
SOLIDITY_BUILD_DIR=${SOLIDITY_BUILD_DIR:-${REPO_ROOT}/build}
SOLC="${SOLIDITY_BUILD_DIR}/solc/solc"
SPLITSOURCES="${REPO_ROOT}/scripts/splitSources.py"

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

function print_usage
{
    echo "Usage: ${0} ast|evm-assembly [--exit-on-error|--help]."
}

function print_used_commands
{
    local test_directory="$1"
    local export_command="$2"
    local import_command="$3"
    printError "You can find the files used for this test here: ${test_directory}"
    printError "Used commands for test:"
    printError "# export"
    echo "$ ${export_command}" >&2
    printError "# import"
    echo "$ ${import_command}" >&2
}

function print_stderr_stdout
{
    local error_message="$1"
    local stderr_file="$2"
    local stdout_file="$3"
    printError "$error_message"
    printError ""
    printError "stderr:"
    cat "$stderr_file" >&2
    printError ""
    printError "stdout:"
    cat "$stdout_file" >&2
}

function check_import_test_type_unset
{
    [[ -z "$IMPORT_TEST_TYPE" ]] || fail "ERROR: Import test type can only be set once. Aborting."
}

IMPORT_TEST_TYPE=
EXIT_ON_ERROR=0
for PARAM in "$@"
do
    case "$PARAM" in
        ast) check_import_test_type_unset ; IMPORT_TEST_TYPE="ast" ;;
        evm-assembly) check_import_test_type_unset ; IMPORT_TEST_TYPE="evm-assembly" ;;
        --help) print_usage ; exit 0 ;;
        --exit-on-error) EXIT_ON_ERROR=1 ;;
        *) fail "Unknown option '$PARAM'. Aborting. $(print_usage)" ;;
    esac
done

SYNTAXTESTS_DIR="${REPO_ROOT}/test/libsolidity/syntaxTests"
ASTJSONTESTS_DIR="${REPO_ROOT}/test/libsolidity/ASTJSON"
SEMANTICTESTS_DIR="${REPO_ROOT}/test/libsolidity/semanticTests"

FAILED=0
UNCOMPILABLE=0
TESTED=0

function test_ast_import_export_equivalence
{
    local sol_file="$1"
    local input_files=( "${@:2}" )

    local export_command=("$SOLC" --combined-json ast --pretty-json --json-indent 4 "${input_files[@]}")
    local import_command=("$SOLC" --import-ast --combined-json ast --pretty-json --json-indent 4 expected.json)

    # export ast - save ast json as expected result (silently)
    if ! "${export_command[@]}" > expected.json 2> stderr_export.txt
    then
        print_stderr_stdout "ERROR: AST reimport failed (export) for input file ${sol_file}." ./stderr_export.txt ./expected.json
        print_used_commands "$(pwd)" "${export_command[*]} > expected.json" "${import_command[*]}"
        return 1
    fi

    # (re)import ast - and export it again as obtained result (silently)
    if ! "${import_command[@]}" > obtained.json 2> stderr_import.txt
    then
        print_stderr_stdout "ERROR: AST reimport failed (import) for input file ${sol_file}." ./stderr_import.txt ./obtained.json
        print_used_commands "$(pwd)" "${export_command[*]} > expected.json" "${import_command[*]}"
        return 1
    fi

    # compare expected and obtained ASTs
    if ! diff_files expected.json obtained.json
    then
        printError "ERROR: AST reimport failed for ${sol_file}"
        if (( EXIT_ON_ERROR == 1 ))
        then
            print_used_commands "$(pwd)" "${export_command[*]}" "${import_command[*]}"
            return 1
        fi
        FAILED=$((FAILED + 1))
    fi
    TESTED=$((TESTED + 1))
}

function split_combined_json
{
    local json_file="$1"
    local output_path="$2"
    local prefix="${3//}"
#    echo "json_file=$(pwd)/$json_file"
    for path_with_contract in $(jq '.contracts | keys | .[]' "$json_file" 2> /dev/null)
    do
        local path=${path_with_contract}
        local contract=""
        local delimiter=$(gexpr index "${path_with_contract}" ":")
        # shellcheck disable=SC2181
        if [[ -z "$prefix" ]]
        then
            path=${path_with_contract:0:(($delimiter - 1))}
            contract=${path_with_contract:(($delimiter)):((${#path_with_contract} - $delimiter - 1))}
        else
            path=${path_with_contract}
            contract=""
        fi
#        echo "path_with_contract: ${path_with_contract}"
#        echo "path: ${path}"
#        echo "contract: ${contract}"
        for type in $(jq --raw-output ".contracts.${path_with_contract} | keys | .[]" "$json_file" 2> /dev/null)
        do
            jq --raw-output ".contracts.${path_with_contract}.\"${type}\"" "$json_file" > "$output_path/$prefix$contract.$type"
        done
    done
#    rm "$json_file"
}

function run
{
    local output_file=$1
    local executable_and_parameters=( "${@:2}" )
#    echo "output_file='$output_file'"
#    echo "executable_and_parameters='${executable_and_parameters[*]}'"
    if ! "${executable_and_parameters[@]}" > "${output_file}" 2> "${output_file}.error"
    then
        failure=1
        printError "ERROR: ${executable_and_parameters[*]}"
        printError "$(pwd)"
        printError "$(cat "${output_file}.error")"
    fi
    rm -f "${output_file}.error"
}

function run_solc
{
    local parameters=( "${@}" )
#    echo "parameters='${parameters[*]}'"
    if ! "${SOLC}" "${parameters[@]}" > /dev/null 2> solc_stderr
    then
        printError "ERROR: ${parameters[*]}"
        printError "$(pwd)"
        printError "$(cat "solc_stderr")"
    fi
    rm -f solc_stderr
}

function run_solc_store_stdout
{
    local output_file=$1
    local parameters=( "${@:2}" )
#    echo "output_file='$output_file'"
#    echo "executable_and_parameters='${parameters[*]}'"
    if ! "${SOLC}" "${parameters[@]}" > "${output_file}" 2> "${output_file}.error"
    then
        failure=1
        printError "ERROR: ${parameters[*]}"
        printError "$(pwd)"
        printError "$(cat "${output_file}.error")"
    fi
    rm -f "${output_file}.error"
}

function test_via_ir_and_yul_import_export
{
    local sol_file="$1"
    local input_files=( "${@:2}" )
    local failure=0

#    pwd
    mkdir yul
    run_solc --optimize --via-ir --ir-optimized "${input_files[@]}" -o yul/
    # remove '_opt' part of '<contract-name>_opt.yul'
    for filename in yul/*; do
        mv "$filename" "${filename/_opt/}"
    done
    find yul/* -size -2c -delete

    mkdir sol
    run_solc --combined-json "bin,bin-runtime,opcodes,asm,srcmap,srcmap-runtime" --optimize --via-ir --pretty-json --json-indent 4 "${input_files[@]}" -o sol/
    split_combined_json sol/combined.json sol/
    find sol/* -size -2c -delete

    for yulfile in yul/*
    do
      run_solc_store_stdout "$yulfile.asm.json" --strict-assembly "$yulfile" --optimize --asm-json --pretty-json --json-indent 4
      gawk -i inplace '!/^=======/' "$yulfile.asm.json"
      run_solc_store_stdout "$yulfile.combined.json" --combined-json "bin,bin-runtime,opcodes,asm,srcmap,srcmap-runtime" --pretty-json --json-indent 4 --import-asm-json "$yulfile.asm.json"
      split_combined_json "$yulfile.combined.json" . "$yulfile"
    done

    for file in sol/*
    do
      local type=$(basename "$file")
      local delimiter=$(gexpr index "${type}" ".")
      type=${type:(($delimiter)):((${#type} - $delimiter))}
      local yul=${file/sol/yul}
      yul=${yul/${type}/yul.${type}}
      if [ "$type" == "asm" ] || [ "$type" == "json" ]
      then
#          echo "skipping diff ${file} ${yul}"
          continue
#      else
#          echo "diff: ${file} ${yul}"
      fi
      if ! diff_files "${file}" "${yul}"
      then
          printError "ERROR: diff failed ${file} ${yul}"
          printError "$(pwd)"
          printError "${sol_file} ${input_files[*]}"
          echo "- ${type} @ ${sol_file}" >> /tmp/all_errors
          echo
#          exit 1
      fi
    done

#    echo

#    exit 0

#    return 0

#    local last_yul_file="yul-00"
#    for file in yul-*
#    do
#      last_yul_file=$file
#    done

#    run yul.asm.json "$SOLC" --strict-assembly "$last_yul_file" --optimize --asm-json
#        gawk -i inplace '!/^=======/' yul.asm.json
#        jq . yul.asm.json  > yul.asm.json.pretty
#        mv yul.asm.json.pretty yul.asm.json
#
#    run yul.asm.imported.json "${SOLC}" --combined-json "bin,bin-runtime,opcodes,asm,srcmap,srcmap-runtime" --pretty-json --json-indent 4 --import-asm-json yul.asm.json
#        split_combined_json yul.asm.imported.json from-yul
#
#    run via-ir.json "${SOLC}" --combined-json "bin,bin-runtime,opcodes,asm,srcmap,srcmap-runtime" --optimize --via-ir --pretty-json --json-indent 4 "${input_files[@]}"
#        split_combined_json via-ir.json from-sol
#
#    local outputs=( "bin" "bin-runtime" "opcodes" )
#    for output in "${outputs[@]}"
#    do
#        if ! diff_files "from-yul.${output}" "from-sol.${output}"
#        then
#          printError "ERROR: diff failed from-yul.${output} from-sol.${output}"
#          printError "$(pwd)"
#          printError "${sol_file} ${input_files[*]}"
#          exit 1
#        fi
#    done
#
    return ${failure}
}

function test_evmjson_import_export_equivalence
{
    local sol_file="$1"
    local input_files=( "${@:2}" )
    local outputs=( "asm" "bin" "bin-runtime" "opcodes" "srcmap" "srcmap-runtime" )
    local export_command=("$SOLC" --combined-json "$(IFS=, ; echo "${outputs[*]}")" --pretty-json --json-indent 4 "${input_files[@]}")
    local success=1

    test_via_ir_and_yul_import_export "$sol_file" "${input_files[@]}"
    success=!$?

    if (( success == 1 ))
    then
        TESTED=$((TESTED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# function tests whether exporting and importing again is equivalent.
# Results are recorded by incrementing the FAILED or UNCOMPILABLE global variable.
# Also, in case of a mismatch a diff is printed
# Expected parameters:
# $1 name of the file to be exported and imported
# $2 any files needed to do so that might be in parent directories
function test_import_export_equivalence {
    local sol_file="$1"
    local input_files=( "${@:2}" )
    local output
    local solc_return_code
    local compile_test

    case "$IMPORT_TEST_TYPE" in
        ast) compile_test="--ast-compact-json" ;;
        evm-assembly) compile_test="--bin" ;;
        *) assertFail "Unknown import test type '${IMPORT_TEST_TYPE}'. Aborting." ;;
    esac

    set +e
    output=$("$SOLC" "${compile_test}" "${input_files[@]}" 2>&1)
    solc_return_code=$?
    set -e

    # if input files where compilable with success
    if (( solc_return_code == 0 ))
    then
        case "$IMPORT_TEST_TYPE" in
            ast) test_ast_import_export_equivalence "${sol_file}" "${input_files[@]}" ;;
            evm-assembly) test_evmjson_import_export_equivalence "${sol_file}" "${input_files[@]}" ;;
            *) assertFail "Unknown import test type '${IMPORT_TEST_TYPE}'. Aborting." ;;
        esac
    else
        UNCOMPILABLE=$((UNCOMPILABLE + 1))

        # solc will return exit code 2, if it was terminated by an uncaught exception.
        # This should normally not happen, so we terminate the test execution here
        # and print some details about the corresponding solc invocation.
        if (( solc_return_code == 2 ))
        then
            # For the evm-assembly import/export tests, this script uses only the
            # old code generator. Some semantic test can only be compiled with
            # --via-ir (some need to be additionally compiled with --optimize).
            # The tests that are meant to be compiled with --via-ir are throwing
            # an UnimplementedFeatureError exception (e.g. Copying of type struct C.S
            # memory[] memory to storage not yet supported, Copying nested calldata
            # dynamic arrays to storage is not implemented in the old code generator.)
            # We will just ignore these kind of exceptions for now.
            # However, any other exception will be treated as a fatal error and the
            # script execution will be terminated with an error.
            if [[ "$output" != *"UnimplementedFeatureError"* ]]
            then
                fail "\n\nERROR: Uncaught Exception while executing '$SOLC ${compile_test} ${input_files[*]}':\n${output}\n"
            fi
        fi
    fi
}

WORKINGDIR=$PWD

command_available "$SOLC" --version
command_available jq --version

case "$IMPORT_TEST_TYPE" in
    ast) TEST_DIRS=("${SYNTAXTESTS_DIR}" "${ASTJSONTESTS_DIR}") ;;
    evm-assembly) TEST_DIRS=("${SEMANTICTESTS_DIR}") ;;
    *) assertFail "Import test type not defined. $(print_usage)" ;;
esac

# boost_filesystem_bug specifically tests a local fix for a boost::filesystem
# bug. Since the test involves a malformed path, there is no point in running
# tests on it. See https://github.com/boostorg/filesystem/issues/176
IMPORT_TEST_FILES=$(find "${TEST_DIRS[@]}" -name "*.sol" -and -not -name "boost_filesystem_bug.sol")

NSOURCES="$(echo "${IMPORT_TEST_FILES}" | wc -l)"
echo "Looking at ${NSOURCES} .sol files..."

for solfile in $IMPORT_TEST_FILES
do
    echo -n "·"
    # create a temporary sub-directory
    FILETMP=$(mktemp -d)
    cd "$FILETMP"

    set +e
    OUTPUT=$("$SPLITSOURCES" "$solfile")
    SPLITSOURCES_RC=$?
    set -e

    if (( SPLITSOURCES_RC == 0 ))
    then
        IFS=' ' read -ra OUTPUT_ARRAY <<< "$OUTPUT"
        test_import_export_equivalence "$solfile" "${OUTPUT_ARRAY[@]}"
    elif (( SPLITSOURCES_RC == 1 ))
    then
        test_import_export_equivalence "$solfile" "$solfile"
    elif (( SPLITSOURCES_RC == 2 ))
    then
        # The script will exit with return code 2, if an UnicodeDecodeError occurred.
        # This is the case if e.g. some tests are using invalid utf-8 sequences. We will ignore
        # these errors, but print the actual output of the script.
        printError "\n\n${OUTPUT}\n\n"
        test_import_export_equivalence "$solfile" "$solfile"
    else
        # All other return codes will be treated as critical errors. The script will exit.
        printError "\n\nGot unexpected return code ${SPLITSOURCES_RC} from '${SPLITSOURCES} ${solfile}'. Aborting."
        printError "\n\n${OUTPUT}\n\n"

        cd "$WORKINGDIR"
        # Delete temporary files
        rm -rf "$FILETMP"

        exit 1
    fi

    cd "$WORKINGDIR"
    # Delete temporary files
    rm -rf "$FILETMP"
done

echo

if (( FAILED == 0 ))
then
    echo "SUCCESS: ${TESTED} tests passed, ${FAILED} failed, ${UNCOMPILABLE} could not be compiled (${NSOURCES} sources total)."
else
    fail "FAILURE: Out of ${NSOURCES} sources, ${FAILED} failed, (${UNCOMPILABLE} could not be compiled)."
fi
