#!/bin/bash
set -e

# Check for required environment variables
if [[ -z "$JWT_SECRET" || -z "$AUTHENTICATOR_PASSWORD" ]]; then
  echo "JWT_SECRET and AUTHENTICATOR_PASSWORD must be set."
  exit 1
fi

# Enable PostGIS, pgcrypto, and pgjwt extensions
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create extensions
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
    CREATE EXTENSION IF NOT EXISTS pgjwt;

    -- Create roles
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD '$AUTHENTICATOR_PASSWORD';
    CREATE ROLE web_anon NOLOGIN;
    CREATE ROLE normal_user NOLOGIN;

    -- Create schemas and tables
    CREATE SCHEMA IF NOT EXISTS challenges;
    CREATE SCHEMA IF NOT EXISTS basic_auth;
    CREATE SCHEMA IF NOT EXISTS config;

    -- Store the JWT secret in a table
    CREATE TABLE IF NOT EXISTS config.settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    -- Insert the JWT secret
    INSERT INTO config.settings (key, value) VALUES ('jwt_secret', '$JWT_SECRET')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

    CREATE TABLE IF NOT EXISTS basic_auth.users (
        email TEXT PRIMARY KEY CHECK (email ~* '^.+@.+\..+$'),
        pass TEXT NOT NULL CHECK (length(pass) < 512),
        role NAME NOT NULL CHECK (length(role) < 512)
    );

    -- Create challenge-related tables
    CREATE TABLE IF NOT EXISTS challenges.challenge_list (
        challenge_id SERIAL PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        "from" DATE NOT NULL,
        "to" DATE NOT NULL,
        type VARCHAR(100) NOT NULL,
        created_by NAME NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'role'
    );

    CREATE TABLE IF NOT EXISTS challenges.challenge_shares (
        challenge_id INT REFERENCES challenges.challenge_list(challenge_id) ON DELETE CASCADE,
        shared_with NAME NOT NULL,
        created_by NAME NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'role',
        PRIMARY KEY (challenge_id, shared_with)
    );

    -- Create challenge_records table
    CREATE TABLE IF NOT EXISTS challenges.challenge_records (
        record_id SERIAL PRIMARY KEY,
        "user" NAME NOT NULL DEFAULT current_setting('request.jwt.claims', true)::json->>'role',
        challenge_id INT REFERENCES challenges.challenge_list(challenge_id) ON DELETE CASCADE,
        timestamp DOUBLE PRECISION NOT NULL,
        type VARCHAR(100) NOT NULL,
        distance DOUBLE PRECISION NOT NULL
    );

    -- Create function to validate record type
    CREATE OR REPLACE FUNCTION challenges.validate_record_type()
    RETURNS TRIGGER AS \$\$
    DECLARE
        challenge_type VARCHAR(100);
    BEGIN
        SELECT type INTO challenge_type
        FROM challenges.challenge_list
        WHERE challenge_id = NEW.challenge_id;

        IF NEW.type <> challenge_type THEN
            RAISE EXCEPTION 'Record type must match challenge type. Expected: %, Got: %', challenge_type, NEW.type;
        END IF;

        RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql;

    -- Create trigger for type validation
    DROP TRIGGER IF EXISTS validate_record_type ON challenges.challenge_records;
    CREATE TRIGGER validate_record_type
        BEFORE INSERT OR UPDATE ON challenges.challenge_records
        FOR EACH ROW
        EXECUTE FUNCTION challenges.validate_record_type();



-- Create function to validate timestamp
    CREATE OR REPLACE FUNCTION challenges.validate_record_timestamp()
    RETURNS TRIGGER AS \$\$
    DECLARE
        challenge_start DOUBLE PRECISION;
        challenge_end DOUBLE PRECISION;
    BEGIN
        SELECT 
            EXTRACT(EPOCH FROM "from"::timestamp),
            EXTRACT(EPOCH FROM ("to"::timestamp + interval '1 day - 1 second'))
        INTO challenge_start, challenge_end
        FROM challenges.challenge_list
        WHERE challenge_id = NEW.challenge_id;

        IF NEW.timestamp < challenge_start OR NEW.timestamp > challenge_end THEN
            RAISE EXCEPTION 'Timestamp must be between challenge start and end dates';
        END IF;

        RETURN NEW;
    END;
    \$\$ LANGUAGE plpgsql;

    -- Create trigger for timestamp validation (modified to avoid warning)
    DROP TRIGGER IF EXISTS validate_record_timestamp ON challenges.challenge_records;
    CREATE TRIGGER validate_record_timestamp
        BEFORE INSERT OR UPDATE ON challenges.challenge_records
        FOR EACH ROW
        EXECUTE FUNCTION challenges.validate_record_timestamp();

    -- Create views with improved access control
    CREATE OR REPLACE VIEW challenges.user_challenges AS
    SELECT cl.*
    FROM challenges.challenge_list cl
    LEFT JOIN challenges.challenge_shares cs ON cl.challenge_id = cs.challenge_id
    WHERE cl.created_by = current_setting('request.jwt.claims', true)::json->>'role' 
       OR cs.shared_with = current_setting('request.jwt.claims', true)::json->>'role';

    CREATE OR REPLACE VIEW challenges.shared_challenges AS
    SELECT cl.*
    FROM challenges.challenge_list cl
    JOIN challenges.challenge_shares cs ON cl.challenge_id = cs.challenge_id
    WHERE cs.shared_with = current_setting('request.jwt.claims', true)::json->>'role';

    CREATE OR REPLACE VIEW challenges.shared_challenge_records AS
    (
        SELECT cr.*
        FROM challenges.challenge_records cr
        JOIN challenges.challenge_list cl ON cr.challenge_id = cl.challenge_id
        WHERE cl.created_by = current_setting('request.jwt.claims', true)::json->>'role'
    )
    UNION
    (
        SELECT cr.*
        FROM challenges.challenge_records cr
        JOIN challenges.challenge_list cl ON cr.challenge_id = cl.challenge_id
        JOIN challenges.challenge_shares cs ON cl.challenge_id = cs.challenge_id
        WHERE cs.shared_with = current_setting('request.jwt.claims', true)::json->>'role'
    );

    CREATE OR REPLACE VIEW challenges.challenge_shares_visibility AS
    SELECT 
        cs.challenge_id,
        cs.shared_with,
        cs.created_by,
        cl.name as challenge_name
    FROM challenges.challenge_shares cs
    JOIN challenges.challenge_list cl ON cs.challenge_id = cl.challenge_id
    WHERE cl.created_by = current_setting('request.jwt.claims', true)::json->>'role';

    -- User management functions
    CREATE OR REPLACE FUNCTION basic_auth.check_role_exists() RETURNS TRIGGER AS \$\$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = NEW.role) THEN
            RAISE EXCEPTION 'Unknown database role: %', NEW.role;
        END IF;
        RETURN NEW;
    END
    \$\$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS ensure_user_role_exists ON basic_auth.users;
    CREATE CONSTRAINT TRIGGER ensure_user_role_exists
    AFTER INSERT OR UPDATE ON basic_auth.users
    FOR EACH ROW
    EXECUTE FUNCTION basic_auth.check_role_exists();

    CREATE OR REPLACE FUNCTION basic_auth.encrypt_pass() RETURNS TRIGGER AS \$\$
    BEGIN
        IF TG_OP = 'INSERT' OR NEW.pass <> OLD.pass THEN
            NEW.pass = crypt(NEW.pass, gen_salt('bf'));
        END IF;
        RETURN NEW;
    END
    \$\$ LANGUAGE plpgsql;

    DROP TRIGGER IF EXISTS encrypt_pass ON basic_auth.users;
    CREATE TRIGGER encrypt_pass
    BEFORE INSERT OR UPDATE ON basic_auth.users
    FOR EACH ROW
    EXECUTE FUNCTION basic_auth.encrypt_pass();

    -- Authentication functions
    CREATE OR REPLACE FUNCTION basic_auth.user_role(email TEXT, pass TEXT) RETURNS NAME AS \$\$
    BEGIN
        RETURN (
            SELECT role 
            FROM basic_auth.users
            WHERE users.email = user_role.email
              AND users.pass = crypt(user_role.pass, users.pass)
        );
    END
    \$\$ LANGUAGE plpgsql;

    CREATE OR REPLACE FUNCTION challenges.login(email TEXT, pass TEXT, OUT token TEXT) AS \$\$
    DECLARE
        _role NAME;
        jwt_secret TEXT;
    BEGIN
        -- Fetch the JWT secret from the settings table
        SELECT value INTO jwt_secret FROM config.settings WHERE key = 'jwt_secret';
        IF jwt_secret IS NULL THEN
            RAISE EXCEPTION 'JWT secret not configured';
        END IF;

        -- Check email and password
        SELECT basic_auth.user_role(email, pass) INTO _role;
        IF _role IS NULL THEN
            RAISE EXCEPTION 'Invalid user or password';
        END IF;

        -- Generate JWT token using pgjwt's sign function
        SELECT sign(
            row_to_json(r), 
            jwt_secret
        ) INTO token
        FROM (
            SELECT 
                email AS role, 
                _role AS group,
                extract(epoch FROM now())::integer + (60 * 60 * 24 * 7) AS exp  -- 7 days expiration
        ) r;
    END
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;

    CREATE OR REPLACE FUNCTION challenges.insert_challenge(challenge_data JSON) RETURNS VOID AS \$\$
    BEGIN
        INSERT INTO challenges.challenge_list (name, "from", "to", type, created_by)
        VALUES (
            challenge_data->>'name',
            (challenge_data->>'from')::DATE,
            (challenge_data->>'to')::DATE,
            challenge_data->>'type',
            current_setting('request.jwt.claims', true)::json->>'role'
        );
    END;
    \$\$ LANGUAGE plpgsql;


-- Grant usage on the sequences
    GRANT USAGE, SELECT ON SEQUENCE challenges.challenge_list_challenge_id_seq TO normal_user;
    GRANT USAGE, SELECT ON SEQUENCE challenges.challenge_records_record_id_seq TO normal_user;

    -- Grant privileges
    GRANT USAGE ON SCHEMA challenges TO web_anon;
    GRANT USAGE ON SCHEMA challenges TO normal_user;
    GRANT ALL ON challenges.challenge_list TO normal_user;
    GRANT ALL ON challenges.challenge_shares TO normal_user;
    GRANT ALL ON challenges.challenge_records TO normal_user;
    GRANT SELECT ON challenges.user_challenges TO normal_user;
    GRANT SELECT ON challenges.shared_challenges TO normal_user;
    GRANT SELECT ON challenges.shared_challenge_records TO normal_user;
    GRANT SELECT ON challenges.challenge_shares_visibility TO normal_user;
    GRANT EXECUTE ON FUNCTION challenges.login(TEXT, TEXT) TO web_anon;
    GRANT EXECUTE ON FUNCTION challenges.insert_challenge(JSON) TO normal_user;



    -- CHALLENGE LIST POLICIES
    ALTER TABLE challenges.challenge_list ENABLE ROW LEVEL SECURITY;
    
    DROP POLICY IF EXISTS select_own_challenges ON challenges.challenge_list;
    CREATE POLICY select_own_challenges
        ON challenges.challenge_list
        FOR SELECT
        USING (
            created_by = current_setting('request.jwt.claims', true)::json->>'role'
            OR
            challenge_id IN (
                SELECT challenge_id 
                FROM challenges.challenge_shares 
                WHERE shared_with = current_setting('request.jwt.claims', true)::json->>'role'
            )
        );

    DROP POLICY IF EXISTS delete_own_challenges ON challenges.challenge_list;
    CREATE POLICY delete_own_challenges
        ON challenges.challenge_list
        FOR DELETE
        USING (created_by = current_setting('request.jwt.claims', true)::json->>'role');

    DROP POLICY IF EXISTS insert_own_challenges ON challenges.challenge_list;
    CREATE POLICY insert_own_challenges
        ON challenges.challenge_list
        FOR INSERT
        WITH CHECK (current_setting('request.jwt.claims', true)::json->>'role' IS NOT NULL);

    -- CHALLENGE SHARES POLICIES
    ALTER TABLE challenges.challenge_shares ENABLE ROW LEVEL SECURITY;
    
    DROP POLICY IF EXISTS delete_own_shares ON challenges.challenge_shares;
    CREATE POLICY delete_own_shares
        ON challenges.challenge_shares
        FOR DELETE
        USING (created_by = current_setting('request.jwt.claims', true)::json->>'role');

    DROP POLICY IF EXISTS select_own_shares ON challenges.challenge_shares;
    CREATE POLICY select_own_shares
        ON challenges.challenge_shares
        FOR SELECT
        USING (
            created_by = current_setting('request.jwt.claims', true)::json->>'role'
            OR
            shared_with = current_setting('request.jwt.claims', true)::json->>'role'
        );

    -- Create a security definer function to check email existence
    CREATE OR REPLACE FUNCTION basic_auth.check_email_exists(email TEXT)
    RETURNS BOOLEAN AS \$\$
    BEGIN
        RETURN EXISTS (
            SELECT 1 
            FROM basic_auth.users 
            WHERE users.email = check_email_exists.email
        );
    END;
    \$\$ LANGUAGE plpgsql SECURITY DEFINER;

    -- Grant execute permission on the function
    GRANT EXECUTE ON FUNCTION basic_auth.check_email_exists(TEXT) TO normal_user;

    -- Modify the policy to use the secure function
    DROP POLICY IF EXISTS create_own_shares ON challenges.challenge_shares;
    CREATE POLICY create_own_shares
    ON challenges.challenge_shares
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM challenges.challenge_list
            WHERE challenge_id = challenge_shares.challenge_id
            AND created_by = current_setting('request.jwt.claims', true)::json->>'role'
        )
        AND
        shared_with <> current_setting('request.jwt.claims', true)::json->>'role'
        AND
        basic_auth.check_email_exists(shared_with)
    );

    -- CHALLENGE RECORDS POLICIES
    ALTER TABLE challenges.challenge_records ENABLE ROW LEVEL SECURITY;
    
    DROP POLICY IF EXISTS delete_own_records ON challenges.challenge_records;
    CREATE POLICY delete_own_records
        ON challenges.challenge_records
        FOR DELETE
        USING ("user" = current_setting('request.jwt.claims', true)::json->>'role');

    DROP POLICY IF EXISTS insert_records ON challenges.challenge_records;
    CREATE POLICY insert_records
        ON challenges.challenge_records
        FOR INSERT
        WITH CHECK (
            "user" = current_setting('request.jwt.claims', true)::json->>'role'
            AND (
                EXISTS (
                    SELECT 1 
                    FROM challenges.challenge_list 
                    WHERE challenge_id = challenge_records.challenge_id
                    AND (
                        created_by = current_setting('request.jwt.claims', true)::json->>'role'
                        OR 
                        challenge_id IN (
                            SELECT challenge_id 
                            FROM challenges.challenge_shares 
                            WHERE shared_with = current_setting('request.jwt.claims', true)::json->>'role'
                        )
                    )
                )
            )
        );

    DROP POLICY IF EXISTS select_records ON challenges.challenge_records;
    CREATE POLICY select_records
        ON challenges.challenge_records
        FOR SELECT
        USING (
            "user" = current_setting('request.jwt.claims', true)::json->>'role'
            OR 
            challenge_id IN (
                SELECT cl.challenge_id
                FROM challenges.challenge_list cl
                LEFT JOIN challenges.challenge_shares cs ON cl.challenge_id = cs.challenge_id
                WHERE cl.created_by = current_setting('request.jwt.claims', true)::json->>'role'
                OR cs.shared_with = current_setting('request.jwt.claims', true)::json->>'role'
            )
        );

EOSQL

# Function to create user with improved logging
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
    fi
}

# Create users based on environment variables
create_user "$USER1_EMAIL" "$USER1_PASSWORD"
create_user "$USER2_EMAIL" "$USER2_PASSWORD"
create_user "$USER3_EMAIL" "$USER3_PASSWORD"
create_user "$USER4_EMAIL" "$USER4_PASSWORD"
create_user "$USER5_EMAIL" "$USER5_PASSWORD"
create_user "$USER6_EMAIL" "$USER6_PASSWORD"
create_user "$USER7_EMAIL" "$USER7_PASSWORD"
create_user "$USER8_EMAIL" "$USER8_PASSWORD"
create_user "$USER9_EMAIL" "$USER9_PASSWORD"
create_user "$USER10_EMAIL" "$USER10_PASSWORD"
create_user "$USER11_EMAIL" "$USER11_PASSWORD"
create_user "$USER12_EMAIL" "$USER12_PASSWORD"
create_user "$USER13_EMAIL" "$USER13_PASSWORD"
create_user "$USER14_EMAIL" "$USER14_PASSWORD"
create_user "$USER15_EMAIL" "$USER15_PASSWORD"
create_user "$USER16_EMAIL" "$USER16_PASSWORD"
create_user "$USER17_EMAIL" "$USER17_PASSWORD"
create_user "$USER18_EMAIL" "$USER18_PASSWORD"
create_user "$USER19_EMAIL" "$USER19_PASSWORD"
create_user "$USER20_EMAIL" "$USER20_PASSWORD"

# Verify user creation
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT email, role FROM basic_auth.users;
EOSQL

# Call the original entrypoint to ensure PostgreSQL starts correctly
#exec docker-entrypoint.sh postgres