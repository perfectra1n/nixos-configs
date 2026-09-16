function find_and_delete_released_wp_pvs
    # Parse command-line flags
    set -l delete_flag 0
    for arg in $argv
        if test "$arg" = "--delete"
            set delete_flag 1
        end
    end

    # Find released PVs with wp- claims
    set -l pvs_to_process (kubectl get pv -o json | jq -c '.items[] | 
        select(
            .status.phase == "Released" and 
            (.spec.claimRef.name | test("^wp-"))
        ) | {
            name: .metadata.name, 
            claim_name: .spec.claimRef.name
        }')

    # Check if any PVs were found
    if test (echo $pvs_to_process | jq -s 'length') -eq 0
        echo "No released PVs with wp- claims found."
        return 0
    end

    # List found PVs
    echo "Found the following released PVs:"
    echo $pvs_to_process | jq -r '.name'

    # Delete PVs if delete flag is set
    if test $delete_flag -eq 1
        echo "Deleting the following PVs:"
        for pv in (echo $pvs_to_process | jq -r '.name')
            echo "Deleting PV: $pv"
            kubectl delete pv $pv
        end
    end
end
