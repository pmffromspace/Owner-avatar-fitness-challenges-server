#!/bin/bash

# Parse command line arguments
email=""
password=""

for i in "$@"
do
case $i in
    username=*)
    email="${i#*=}"
    shift
    ;;
    password=*)
    password="${i#*=}"
    shift
    ;;
    *)
    # unknown option
    ;;
esac
done

create_user() {
    local email=$1
    local password=$2
    local role="normal_user"

    if [[ -n "$email" && -n "$password" ]]; then
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
            DO \$\$
            DECLARE
                _user_id TEXT;
            BEGIN
                IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$email') THEN
                    CREATE ROLE "$email" WITH LOGIN PASSWORD '$password' IN ROLE normal_user;
                END IF;
                
                INSERT INTO basic_auth.users (email, pass, role) 
                VALUES ('$email', '$password', '$role')
                ON CONFLICT (email) 
                DO UPDATE SET pass = '$password', role = '$role'
                RETURNING email INTO _user_id;

                RAISE NOTICE 'User created/updated: %', _user_id;
            END
            \$\$;
EOSQL
    else
        echo "Error: Both email (username) and password must be provided."
        echo "Example: bash add-user.sh username=\"test@example.com\" password=\"securepassword\""
        exit 1
    fi
}

# Call the function with parsed arguments
create_user "$email" "$password"
