# Why?
This guide is made to ease process of setting automation of archiving a mysql database managed by DigitalOcean.

# Disclaimer and credits
This guide heavily depends and almost copies [series of articles](https://dev.to/borama/series/4701) by [Matouš Borák](https://dev.to/borama) written for [NejŘemeslníci](https://dev.to/nejremeslnici).
So make sure to check the original articles and his links:
- [github](https://github.com/borama)
- [twitter](https://twitter.com/boramacz)

# Requirements:
- The table is required to have a unique primary key with TIMESTAMP datatype to distinct each row by date. This guide takes use of primary key named requestTime;
- [DigitalOcean's](https://www.digitalocean.com/) managed database
- [MySQL](https://www.mysql.com/)
- [NodeJS](https://nodejs.org/) (or any other cli tool for creating strings)
- [gh-ost](https://github.com/github/gh-ost)
- Bash 4 (at least)

# I. Initial manual creation of partitions through nodejs cli
We will create first partitions for the table manually. That will ease the process of starting up automatic archivation.
That will be achieved with automatically creating strings for query using nodejs cli tools.

## Generate initial partition strings for query
0. Run in the terminal the following command to enter node cli.
```
node
```
1. Replace 'from' and 'to' with your actual start and end date:
```
const fromDate = new Date('from');const toDate = new Date('to');
```
Then run this line:
```
for (let date = new Date(fromDate); date < toDate; date.setDate(date.getDate() + 1)) {if (date.getDate() === 1) {const nextMonth = new Date(date);nextMonth.setMonth(date.getMonth() + 1);const formattedMonth = ('0' + (date.getMonth() + 1)).slice(-2);const formattedYear = date.getFullYear();const formattedDate = `${formattedMonth}${formattedYear}`;const nextMonthFormatted = nextMonth.toISOString().split('T')[0];console.log(`PARTITION ${formattedDate} VALUES LESS THAN (TO_DAYS('${nextMonthFormatted}')),`);}}
```
2. Copy the output
3. Exit the nodejs cli with CTRL+D

## Add temporary unique primary key
Unfortunately, gh-ost does not support directly restructuring the primary key.

So we will use a neat trick mentioned in their docs:
in the 1st migration we will add a temporary unique key (ADD UNIQUE KEY temp_pk (id, requestTime))
and in the 2nd migration we will replace the primary key with this temporary key (DROP PRIMARY KEY, DROP KEY temp_pk, ADD PRIMARY KEY (id, requestTime))), besides the partitioning itself.

This is why, in effect, we need two separate migrations to partition each of our tables.

```./utils/run_ghost.sh my_huge_table 'ADD UNIQUE KEY temp_pk (id, requestTime)' --execute```

## Create partitions with gh-ost
Replace {__PASTE_HERE__} with the output generated on previous stage:

```
./utils/run_ghost.sh TABLE_NAME "DROP PRIMARY KEY, DROP KEY temp_pk, ADD PRIMARY KEY (id, requestTime) PARTITION BY RANGE(TO_DAYS(requestTime)) ({__PASTE_HERE__} PARTITION future VALUES LESS THAN (MAXVALUE))" --execute
```

# II. Exporting old data from the table
We are using DigitalOcean services for keeping a managed database.
In order to connect to a DO database we need to specify DO_UUID, DO_TOKEN and MYSQL_USER_ALIAS variables in terminal. Example:
```
SET DO_UUID=45dd2d3f-2n9e-40e5-9f7d-13a3541abe2c
SET DO_TOKEN=dop_v1_b92e78646237c539fd633e632d8d0255a597f51dbd1fb34dff044a967cf366ff
mysql_config_editor set --login-path=sample_alias --host=localhost --user=root --password
SET MYSQL_USER_ALIAS=sample_alias
```
A small shell script, manual-export.sh, will export data from the given table and partition name into a gzipped file.

We need to run it for each month of the required year. So we can use bash for loop to do exactly that:
```
for m in 01 02 03 04 05 06 07 08 09 10 11 12; do ./manual-export.sh TABLE_NAME "m2021$m"; done
```

In case something goes wrong, do not try to kill the process, instead use the ”panic button“ in the script, i.e. uncomment the exit line, save the file and the rest of the loop won't run.

## Restoring data from the archive
```
gunzip /archive/TABLE_NAME/TABLE_NAME_m202101.gz | mysql
```

# III. Automation

## Auto-archival configuration
The script autoarchive-tables.sh reads its tasks from a simple configuration file autoarchived-tables.txt, which can look like this:

```
# Configuration for tables auto-archival.
#
# Format:
# table_name interval keep

my_huge_table monthly 6
less_relevant_huge_table monthly 12
quickly_growing_table weekly 12
slowly_growing_table yearly 1
```

Be sure to edit at least the $database variable in the script before you try to run it.

The script is supposed to be periodically called from cron.
