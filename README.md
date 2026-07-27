# Data Analytics for Business - an ERP Use case
ERP systems are massive, they have mostly over 1000 tables intertwined and inter-dependent.
ERPNext is not an exception to this complexity.

I am particularly interested in working with ERPNext
given that its fully open-source. I am actively involved in the transformation and digitization 
of businesses in Kenya, and ERPNext has been such  had a massive impact in how I package ERP solutions
to businesses and organizations in Kenya.

While ERPNext excels in managing a business and its related data (with little optimization) i.e accounting (finance), 
sales, procurement, assets, HRMS, CRM - it is not particularly suitable for uncovering insights. ERPnext has its own report
functionality which can be used to understand the core business operations but delving deeper into insights usually requires customizaing the reports.

In addition to that, new businesses and even existing ones, still lack the technical capacity of the intertwinned nature of ERP systems
which usually limits the capacity to uncover insights from business data.

Albeit, what businesses lack in technical capacity, they make up for in business acquity. And with the continous engagement with accountants, sales managers, logistics officers - data analytics engineers can leverage SQL (mostly) to guide businesses with data driven decision making.

The purpose of this repository is to illustrate how data analytics can be approached in a business, specifically one using ERPNext as the 
core ERP system.

Similar approach can be used on any other ERP System, provided that the Online Transaction Processing Database (OLTP) can be accessed, or is solely available  to the business.

# The Scale
The scale of the business will most likely determine the approach to data analytics. What do I mean by this ?
Businesses operate on different frequencies - volume of revenue or capital, volume of transactions, and volume of users.  
Based on these factors, this repository is based on a business with a high frequency on those three frequencies. 

High number of transactions mean that the database has a medium to high load, with high read and write operations. Revenue and capital, speaking in Kenyan terms, determine how a business is willing to invest in a scalable data strategy. The number of users determine the level of feedback 
we can be able to get from users who interact with the systems daily.

In my opinion, these factors determine the direction a business will take with regards to their overall IT strategy and specifically the data strategy.


# Technical Overview
The current business use case fow which this solution fits, is a case where the OLTP Database (MariaDB) has between hundreds of thousands to millions of rows in some tables.
ERPNext relises heavily on transactions, where an operation such as sales triggers several other read and write operations in other tables i.e inventory, accounting ledgers, user logs.
There are 70 active users in the setup, doing different activties inclusing generating reports. This therefore means that having an analytics 
platform connected to the database directly will increase even more stress on the database. So we would have solved the problem of insights but
introduced another problem.

## The data engineeing lifecycle perspective
Instead of having our analytics software (Metabase - opensource) connected directly on the same OLTP database, I decided that we sould have 
another database (data warehouse), where the analytics platform will be extracting insights from.
The mountain to climb is therefore to organize the data analytics infrastrusture (in a less costly manner), which will give the best value
but also enable the team to make data driven decisions from.

### Data Ingestion


### Data Transformation
- Apache Spark, dbt

### The data model


### Orchestration
- Apache Airflow

### Monitoring
- Prometheus, Grafana

### Data analytics
- Metabase