#!/bin/bash

# MySQL credentials
MYSQL_USER=root
MYSQL_PASS=rootpassword
MYSQL_CONN="-u${MYSQL_USER} -p${MYSQL_PASS}"

# SQL query to collect database names excluding system databases
SQL="SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema')"

# File to store database names
DBLISTFILE=/tmp/DatabasesToDump.txt

# Execute SQL query and save results to file
mysql ${MYSQL_CONN} -ANe"${SQL}" > ${DBLISTFILE}

# Loop through each database and dump it separately
for DB in $(cat ${DBLISTFILE}); do
    echo "Dumping database: ${DB}"
    
    # Set dump file name based on database name
    DUMPFILE="${DB}.sql"
    
    # Dump options
    MYSQLDUMP_OPTIONS="--routines --triggers --single-transaction"
    
    # Dump the database
    mysqldump ${MYSQL_CONN} ${MYSQLDUMP_OPTIONS} ${DB} > ${DUMPFILE}
    
    echo "Dump completed for ${DB} and saved to ${DUMPFILE}"
done
